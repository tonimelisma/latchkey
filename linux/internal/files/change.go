package files

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/tonimelisma/latchkey/linux/internal/tools"
)

var changeActions = []string{"write", "append", "edit", "create_folder", "move", "copy", "delete"}

func (f *Files) changeTool() tools.Tool {
	return tools.Tool{
		Def: tools.Make(tools.Spec{
			Name: "files_change", Title: "Change Files",
			Description: "Changes files on the server. action: write (path, text; an existing file only with overwrite), append (path, text: added at the end), " +
				"edit (path, find: an exact passage that appears once, text: its replacement), create_folder (path), move or copy (path, to: the new path or " +
				"a folder to put it in; never replaces an existing file), delete (path: removes the file, or the folder with everything in it, for good; " +
				"there is no trash on a server).",
			Input: map[string]any{
				"action":    tools.Enum(changeActions, "What to do"),
				"path":      tools.String("The file or folder"),
				"text":      tools.String("The text to write, add, or put in place of find"),
				"find":      tools.String("For edit: the exact passage to replace"),
				"to":        tools.String("For move and copy: where to"),
				"overwrite": tools.Bool("For write: replace an existing file"),
			},
			Required: []string{"action", "path"}, Destructive: true,
		}),
		Run: f.change,
	}
}

func (f *Files) change(_ context.Context, a tools.Args) tools.Result {
	action, err := a.String("action")
	if err != nil {
		return tools.Failf("%v", err)
	}
	p, err := a.String("path")
	if err != nil {
		return tools.Failf("%v", err)
	}
	if strings.TrimSpace(p) == "" {
		return tools.Failf("Give the path.")
	}
	path := f.resolve(p)
	if f.isOwn(path, true) {
		return tools.Failf("%s is one of Latchkey's own files, or holds them; Files can read them but never changes them.", path)
	}
	text, _ := a.String("text")
	switch action {
	case "write":
		overwrite, err := a.Bool("overwrite", false)
		if err != nil {
			return tools.Failf("%v", err)
		}
		return writeFile(path, text, overwrite, false)
	case "append":
		return writeFile(path, text, true, true)
	case "edit":
		find, _ := a.String("find")
		return editFile(path, find, text)
	case "create_folder":
		if err := os.MkdirAll(path, 0o755); err != nil {
			return tools.Failf("%s", describeErr(path, err))
		}
		return tools.Text("Created the folder " + path + ".")
	case "move", "copy":
		to, _ := a.String("to")
		if strings.TrimSpace(to) == "" {
			return tools.Failf("Give to: where to %s it.", action)
		}
		dest := f.resolve(to)
		if info, err := os.Stat(dest); err == nil && info.IsDir() {
			dest = filepath.Join(dest, filepath.Base(path))
		}
		if f.isOwn(dest, false) {
			return tools.Failf("%s is inside Latchkey's own files; Files never changes them.", dest)
		}
		if action == "move" {
			return move(path, dest)
		}
		return copyAny(path, dest)
	case "delete":
		return f.remove(path)
	}
	return tools.Failf("action must be one of %s.", strings.Join(changeActions, ", "))
}

// isOwn reports whether path is one of Latchkey's own files or inside one of its folders, after
// resolving links and "..", so another spelling doesn't get past (FR-1043). With holding, a
// folder that holds one of them counts too (moving or deleting it would take them along).
func (f *Files) isOwn(path string, holding bool) bool {
	real := realPath(path)
	for _, own := range f.Own {
		o := realPath(own)
		if within(real, o) || (holding && within(o, real)) {
			return true
		}
	}
	return false
}

// realPath resolves links in the longest part of path that exists.
func realPath(path string) string {
	path = filepath.Clean(path)
	rest := ""
	for p := path; ; p = filepath.Dir(p) {
		if r, err := filepath.EvalSymlinks(p); err == nil {
			return filepath.Join(r, rest)
		}
		if p == filepath.Dir(p) {
			return path
		}
		rest = filepath.Join(filepath.Base(p), rest)
	}
}

func within(path, folder string) bool {
	return path == folder || strings.HasPrefix(path, strings.TrimSuffix(folder, "/")+"/")
}

func writeFile(path, text string, existingOK, appendTo bool) tools.Result {
	info, err := os.Stat(path)
	exists := err == nil
	if exists && info.IsDir() {
		return tools.Failf("%s is a folder.", path)
	}
	if exists && !existingOK {
		return tools.Failf("%s already exists; pass overwrite to replace it, or use append or edit.", path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return tools.Failf("%s", describeErr(filepath.Dir(path), err))
	}
	flags := os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	if appendTo {
		flags = os.O_WRONLY | os.O_CREATE | os.O_APPEND
	}
	file, err := os.OpenFile(path, flags, 0o644)
	if err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	_, err = io.WriteString(file, text)
	if err = errors.Join(err, file.Close()); err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	switch {
	case appendTo:
		return tools.Text(fmt.Sprintf("Added %d characters to %s.", len([]rune(text)), path))
	case exists:
		return tools.Text(fmt.Sprintf("Replaced %s (%d characters).", path, len([]rune(text))))
	}
	return tools.Text(fmt.Sprintf("Saved %s (%d characters).", path, len([]rune(text))))
}

func editFile(path, find, text string) tools.Result {
	if find == "" {
		return tools.Failf("Give find: the exact passage to replace.")
	}
	info, err := os.Stat(path)
	if err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	switch n := strings.Count(string(data), find); n {
	case 0:
		return tools.Failf("The passage isn't in %s; read the file and copy it exactly.", path)
	case 1:
	default:
		return tools.Failf("The passage appears %d times in %s; give a longer one that appears once.", n, path)
	}
	out := strings.Replace(string(data), find, text, 1)
	if err := os.WriteFile(path, []byte(out), info.Mode().Perm()); err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	return tools.Text("Changed the passage in " + path + ".")
}

func move(from, to string) tools.Result {
	if _, err := os.Lstat(from); err != nil {
		return tools.Failf("%s", describeErr(from, err))
	}
	if _, err := os.Lstat(to); err == nil {
		return tools.Failf("%s already exists; moving never replaces a file.", to)
	}
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return tools.Failf("%s", describeErr(filepath.Dir(to), err))
	}
	err := os.Rename(from, to)
	if errors.Is(err, syscall.EXDEV) { // another disk: copy, then remove
		if r := copyAny(from, to); r.IsError {
			return r
		}
		err = os.RemoveAll(from)
	}
	if err != nil {
		return tools.Failf("%s", describeErr(from, err))
	}
	return tools.Text(fmt.Sprintf("Moved %s to %s.", from, to))
}

func copyAny(from, to string) tools.Result {
	info, err := os.Lstat(from)
	if err != nil {
		return tools.Failf("%s", describeErr(from, err))
	}
	if _, err := os.Lstat(to); err == nil {
		return tools.Failf("%s already exists; copying never replaces a file.", to)
	}
	if info.IsDir() && within(realPath(to), realPath(from)) {
		return tools.Failf("A folder can't be copied into itself.")
	}
	n := 0
	err = filepath.WalkDir(from, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(from, p)
		dest := filepath.Join(to, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			return os.MkdirAll(dest, info.Mode().Perm()|0o700)
		case d.Type()&fs.ModeSymlink != 0:
			target, err := os.Readlink(p)
			if err != nil {
				return err
			}
			n++
			return os.Symlink(target, dest)
		case d.Type().IsRegular():
			n++
			return copyFile(p, dest, info.Mode().Perm())
		}
		return nil // sockets and devices are left out
	})
	if err != nil {
		return tools.Failf("Copying stopped: %s", describeErr(from, err))
	}
	if info.IsDir() {
		return tools.Text(fmt.Sprintf("Copied the folder %s to %s (%d files).", from, to, n))
	}
	return tools.Text(fmt.Sprintf("Copied %s to %s.", from, to))
}

func copyFile(from, to string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	src, err := os.Open(from)
	if err != nil {
		return err
	}
	defer func() { _ = src.Close() }()
	dst, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	_, err = io.Copy(dst, src)
	return errors.Join(err, dst.Close())
}

// remove deletes for good (FR-1042), never the home folder or the disk's root.
func (f *Files) remove(path string) tools.Result {
	real := realPath(path)
	if real == "/" || real == realPath(f.Home) || within(realPath(f.Home), real) {
		return tools.Failf("Deleting %s would delete the home folder; delete what's inside it instead.", path)
	}
	info, err := os.Lstat(path)
	if err != nil {
		return tools.Failf("%s", describeErr(path, err))
	}
	if !info.IsDir() {
		if err := os.Remove(path); err != nil {
			return tools.Failf("%s", describeErr(path, err))
		}
		return tools.Text(fmt.Sprintf("Deleted %s for good (%s).", path, size(info.Size())))
	}
	n := 0
	_ = filepath.WalkDir(path, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			n++
		}
		return nil
	})
	if err := os.RemoveAll(path); err != nil {
		return tools.Failf("Deleting stopped partway: %s", describeErr(path, err))
	}
	return tools.Text(fmt.Sprintf("Deleted the folder %s and the %d files in it for good.", path, n))
}
