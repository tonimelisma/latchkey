# Regression coverage

Every issue found in Latchkey gets an automated test in the lowest layer that reproduces it
(fast, integration, or the sandbox Mac), in the same commit as its fix (spec 016 FR-1609). This
page lists every case of the retired screen-state kit (hand-run against Toni's Mac through the
hosted relay; retired 2026-11-26, spec 016 D5) and what covers each now. A new issue gets its
row here in the same commit as its fix and test.

Covered by:
- **test**: an automated test that fails if the fix is undone and runs in CI (Mac tests in
  `mac-build.yml`, relay and Linux tests in `ci.yml`, the `e2e mac` checks in `e2e.yml`).
- **sandbox check `name`**: a check of the sandbox Mac, for what only the installed app with
  the real Mac apps shows (`make -C macos sandbox`, `relay/cmd/e2e/sandbox*.go`). Which are
  written and which are still to write: `relay/e2e/sandbox-checks.md`, "Status".
- **eval task `id`**: a task in `relay/e2e/tasks/` whose `covers` names the case (real Claude
  in the sandbox Mac; `TestTaskLinesAreKnown` checks each such case's row here names its task).
- **Toni's conditions**: needs the Mac locked, the lid closed, Toni's own accounts, or a real
  site; listed in `docs/screen-states.md`, "Toni's conditions", and NOT VERIFIED until he runs
  it.
- **none**: nothing checks it. A tool's description wording is not tested (Toni, 2026-11-26:
  the tool snapshots were removed).

Counted 2026-11-26: 123 regression cases (90 a test alone; 31 a test plus a sandbox check, an
eval task, or Toni's conditions; 2 Toni's conditions alone) and 114 use cases.

The **Why** column is from the survey of 2026-11-24 (pull request #41, which added the tests
then written new) and later fixes. Found while writing those tests and fixed in the same pull
request: a deleted note read through Notes' scripting still gave Notes' raw "-1728" error;
notes_find with only a bad limit listed the folders and wasn't an error.

## Regressions (`regressions`)

| Case | Covered by | Test | Why |
|---|---|---|---|
| `gmail_create_filter_click` | test | macos/Tests/BrowserActionTests.swift › aCopyDrawnOverAnotherTakesTheClick; clickPressesDownAndUpThenClicksOnce | Fixes 38cda74 (click reaches the copy drawn on top) and 8780081 (press down/up before click) came with these local-page tests; real Gmail's own form can't be automated |
| `gmail_first_read_drawn` | test | macos/Tests/BrowserActionTests.swift › aPageIsReadOnceItStopsChanging | Fix f440517 (read waits until the page stops changing) came with a "Loading..." page drawn later; real Gmail can't be automated |

## Regressions: browser (`regressions-browser`)

| Case | Covered by | Test | Why |
|---|---|---|---|
| `report_holds_the_chats_pages` | test + sandbox check `report-from-installed-app` | relay/internal/mcpserver/fullreport_test.go › TestReportCarriesEverythingForThatChat; macos/Tests/ReportPartTests.swift › thePageIsRecordedFromAWorldItCantSee, thePageIsDescribedWithItsFieldsBlanked | The relay, the Mac's record and description are tested; a real report from the installed app needs sharing on and the developer's key |
| `browser_claudes_tab_sent_on` | test | macos/Tests/BrowserTabTests.swift › OwnerTabNavigationTests.claudesOwnTabIsUsedAfterTheSiteSendsItOn; macos/Tests/BrowserOwnerTabTests.swift › BrowserOwnerTabTests.aClickThatSendsTheTabOffIsSaidToHaveRun; macos/Tests/SignInRoutingTests.swift › signingInAgainOnAnOwnSiteMovesThatPageIntoSafari | Tab sent on by the site is found again, a click that sends the tab off is "Done"; the third part (remembered Safari fallback) was withdrawn on 2026-11-22 (FR-1374, nothing remembered), which the routing test pins |
| `browser_new_tab_sent_on` | test | macos/Tests/BrowserTabTests.swift › OwnerTabNavigationTests.aNewTabTheSiteSendsOnAtOnceIsStillClaudes | eBay's redirect before the first look, with the stand-in Safari; a changed owner's tab still loses it |
| `browser_own_window_size` | test | macos/Tests/LockedBrowserTests.swift › thePageIsInABrowserSizedWindowThatNeverShows | Same expression as the case: outerWidth==innerWidth, outerHeight==innerHeight+90, screenY>=0 |
| `logins_failed_sign_in_guidance` | none | none: it is the tool's description, which no test pins (Toni, 2026-11-26) | the "refused" judging is gone with fill-only (typesTheUserNameThenThePasswordAndPressesTheButtonClaudeNamed) |
| `browser_page_saves_a_file` | test | macos/Tests/BrowserSavedFilesTests.swift › aFileThePageMakesIsSavedDuringClaudesScriptAndThePageStays and the rest of the suite | added with the fix (#40): local pages that save files, through a real WebKit view |
| `browser_background_by_default` | test | macos/Tests/SignInRoutingTests.swift › pagesOpenInTheBackgroundBrowserUnlessShown, aSignedInSiteIsNotMovedToSafariOnItsOwn | added with the fix (#40): no Safari tab unless show_in_safari, with the stand-in Safari |
| `logins_silent_refusal_guidance` | none | none: it is the tool's description, which no test pins (Toni, 2026-11-26) | added with the fix (#40): the tool description says what to do when a site refuses without words |
| `logins_fill_only` | test | macos/Tests/SignInFillTests.swift › aPasswordGoesOnlyIntoAPasswordFieldAndOnlyWithAButton; typesTheUserNameThenThePasswordAndPressesTheButtonClaudeNamed | Password into a text field is refused with nothing pressed; user then password+press works and no answer says "Signed in" |
| `messages_delete_one` | test + sandbox check `messages-identical-texts` | macos/Tests/PendingCleanupTests.swift › MessagesDeleteTests.deletesTheMessageClaudeNames | messages_delete deletes the named id through the cleanup and answers "Deleted message"; the real Messages window delete needs the owner's Mac unlocked |
| `mail_find_read` | test | macos/Tests/PendingCleanupTests.swift › MailToolsTests.findsReadsAndArchives; theIndexIsReadAsMailKeepsIt | mail_find lists id, sender, subject; mail_read gives From, Subject, text, on a stand-in Mail and a real-layout index |
| `browser_closed_menu_links` | test | macos/Tests/LockedBrowserTests.swift › linksBehindACollapsedButtonAreListed; aClosedMenusLinksAreListedAndTheMenuOpens | GitHub's aria-expanded/aria-controls list hidden by CSS: links marked "(in a closed menu «More options»)", button state "collapsed" |
| `browser_linkedin_cancel_sign_in_click` | test + Toni's conditions | RegressionBrowserBTests.swift › aClickThatChangesNothingSaysSoAndWhatToTryNext | No fix for LinkedIn's link was found in history (case added in fdd368a without a code change), and its page's handler is LinkedIn's own, so the "click works without key Enter" part needs the live site; tested only Latchkey's part: an ignored click says nothing changed and suggests key Enter |
| `browser_shadow_root_fields` | test | macos/Tests/SignInFillTests.swift › fieldsInsideShadowRootsAreListedTypedAndEmptied | Etsy-like web components: email and password fields inside shadow roots are listed, typed into, emptied |
| `browser_page_visible` | test | macos/Tests/LockedBrowserTests.swift › pagesAreVisibleAndGetAnimationFramesFromAWindowNeverOnScreen | Same rAF script as the case gives "raf", visibilityState "visible", window never on screen |
| `browser_toggle_state` | test | macos/Tests/LockedBrowserTests.swift › aToggleStateIsShownAndItsChangeCounts | aria-pressed shown as "(not pressed)"/"pressed" and its change is not "unchanged" |
| `logins_code_without_user` | test | macos/Tests/SignInFillTests.swift › noSignInForTheSiteSeveralUserNamesAndHttpsOnly | With two saved users, a code Claude passes is typed without user ("a code Claude passes needs no user") |
| `mail_find_says_cut_off` | test | macos/Tests/RegressionMailBTests.swift › RegressionMailBTests.mailFindSaysWhenItStopsAtThirty | 45 matches: 30 listed plus "there may be more" and how to narrow; 29: nothing about more (no test pinned the note before) |
| `browser_locked_sign_in_guidance` | Toni's conditions | none: it is the tool's description, which no test pins (Toni, 2026-11-26) | Pins "while it is locked, tell the owner the site needs the Mac unlocked" (the old check `contains("locked")` also matched "unlocked"); Target's own page not rendering (an open bug in Latchkey, cause not found yet) needs the live site |
| `logins_uber_code_boxes` | test | macos/Tests/SignInFillTests.swift › boxesNamedOneOfFourTakeADigitEach | Four boxes "Enter an OTP Code n of 4", each in its own wrapper: "(4 boxes)" and the page goes on |
| `messages_delete_uber_code_texts` | test + sandbox check `messages-identical-texts` | macos/Tests/RegressionMessagesBTests.swift › RegressionMessagesBTests.identicalCodeTextsAreToldApartByHowManyLikeThemComeLater (also PendingCleanupTests.swift › SameTextPickTests, whyItCouldntIsSaidAndItIsntTriedForever) | New: Messages' database counts alike texts later/earlier (same side only) and pick() finds each at its place; the Accessibility window and what seen() reports need Messages on screen |
| `logins_out_of_time` | test + Toni's conditions | macos/Tests/RegressionLoginsBTests.swift › RegressionLoginsBTests.aFillAnswersInTimeOnAPageThatKeepsChangingAndLeavesNoPassword | logins_fill's deadline is <=30 s (relay max 60 s); on a page that never settles after the press it answers in <25 s and the password field is empty; Costco itself needs the live site |
| `logins_locked_citi_slow` | test + Toni's conditions | macos/Tests/RegressionLoginsBTests.swift › RegressionLoginsBTests.whileLockedASlowSignInIsAnsweredWithThePageAndNotJudged | With the lock stand-in on: a page still "signing you on" is answered as it is, no "refused"/"Signed in", the page stays in Latchkey's own browser, the password can be typed again; Citi while really locked is Toni's |
| `browser_script_return` | test | macos/Tests/LockedBrowserTests.swift › aScriptThatReturnsWithoutAwaitRuns | "var x = 2; return JSON.stringify(...)" runs and returns {"x":6}; Safari's route via PageScripts.returnsOutsideFunction |
| `browser_tabs_left_open` | test | macos/Tests/RegressionBrowserBTests.swift › RegressionBrowserBTests.aPageWhoseSafariTabIsGoneIsForgottenWhenClosed (and BrowserOwnerTabTests.swift › claudesSafariTabsCloseAtQuit) | The quit part was covered; new: closing a page whose Safari tab is gone says Latchkey forgot it and it is no longer listed, owner's tabs untouched (cb01624's tabGone branch had no test) |
| `browser_press_before_click` | test | macos/Tests/BrowserActionTests.swift › PageActionScriptTests.clickPressesDownAndUpThenClicksOnce | Click sends pointerdown, mousedown, pointerup, mouseup inside the element, then one click; "locked" just means Latchkey's own browser (LockedBrowserActionTests.everyActionWorksInLatchkeysOwnBrowser) |
| `browser_click_covered_copy` | test | macos/Tests/BrowserActionTests.swift › PageActionScriptTests.aCopyDrawnOverAnotherTakesTheClick | The copy underneath is marked "(under another element)" and a click on it reaches the copy on top |
| `browser_click_changed_nothing_said` | test | macos/Tests/RegressionBrowserBTests.swift › RegressionBrowserBTests.aClickThatChangesNothingSaysSoAndWhatToTryNext | The decision was covered (aClickThatChangesNothingIsToldApart) but not the answer; new test runs browser_act click and checks the note and its suggestion, and no note for a click that changes the page |
| `browser_signed_in_site_no_cookie_copy` | test + Toni's conditions | macos/Tests/SignInRoutingTests.swift › aSignedInSiteOpensInASafariTabOfClaudesWhileUnlocked; copiesOnlyWhileLockedAndForgottenAtUnlock; safariOnlyWhileUnlockedAndOnlyForSignedInSites | A signed-in site opens in a Safari tab of Claude's while unlocked, no cookies copied while unlocked; the owner's real Target sign-in is live-only |
| `browser_hidden_page_search_results` | test + Toni's conditions | macos/Tests/LockedBrowserTests.swift › pagesAreVisibleAndGetAnimationFramesFromAWindowNeverOnScreen; SignInRoutingTests.swift › aSignedInSiteOpensInASafariTabOfClaudesWhileUnlocked | Latchkey's part (pages visible with animation frames; signed-in sites to Safari while unlocked) is tested; whether Target's own search draws results needs the live site |
| `browser_costco_orders_not_stuck` | test + Toni's conditions | macos/Tests/BrowserActionTests.swift › LockedBrowserActionTests.aPageIsReadOnceItStopsChanging; LockedBrowserTests.swift › pagesAreVisibleAndGetAnimationFramesFromAWindowNeverOnScreen | Latchkey reads a "Loading..." page once it has drawn and pages are visible; Costco's own orders page needs the live site |
| `browser_locked_sign_in_fresh` | test + Toni's conditions | macos/Tests/LockedBrowserTests.swift › safarisCookiesAreTakenAgainWithEachPageClaudeOpens; aLostSignInComesBackAndThePagesOwnCookiesStay | Safari's cookies are copied again before each page, and takeSafarisCookies (what sign_in_again calls) restores a lost sign-in; the owner's real Amazon while locked is Toni's |
| `browser_pages_open_quickly` | test | macos/Tests/LockedBrowserTests.swift › aPageTakesOnlyItsSitesCookiesAndOpensFast | 3,501 Safari cookies: a page takes only its site's and opens in seconds |
| `browser_pages_by_name_isolated` | test | macos/Tests/OwnPagesTests.swift › OwnPagesTests.eachPageOpenedWithoutANameIsANewOne; OwnPagesToolTests.openingTwiceGivesTwoNamedPagesAndNoSafariTab; aURLWithoutPageNeverLoadsIntoAnotherChatsSafariPage | Each url without page is a new named page, the first keeps its content, another chat's tab isn't touched |
| `browser_confirm_from_click_no_freeze` | test | macos/Tests/OwnPagesTests.swift › HeldDialogTests.aConfirmDuringClaudesScriptIsToldAtOnceAndCancelAnswersIt, aLateConfirmWaitsForClaudeAndOKAnswersIt; macos/Tests/BrowserDialogTests.swift › aWaitingTabIsToldAtOnceAndLeftAlone; macos/Tests/OwnPagesTests.swift › OwnPagesToolTests.claudeAnswersTheDialogWithBrowserAct | Fix 4a50e8d: a confirm in Claude's page is held and told at once, answered with browser_act dialog; 0d153f8's waiting Safari tab is told at once (all fail if reverted) |
| `browser_busy_tab_not_called_dialog` | test + sandbox check `safari-busy-tab` | macos/Tests/RegressionBrowserCTests.swift › RegressionBusyTabCTests.theTabChecksWaitTenSecondsBeforeCallingATabWaiting, aTabThatDidntAnswerIsSaidBusyFirstADialogOnlyMaybe | Fix 26501e0 (6 s to 10 s in the tab check scripts, wording) had no test; pinned now; real Safari's 12 s first-script delay needs the owner's Safari |
| `browser_locked_tabs_answer_in_time` | test | macos/Tests/BrowserOwnerTabTests.swift › LockedSafariTests.aStalledSafariIsToldInTimeWhileLocked | Added in fix 9bfeb97: while locked the short runner is used and the list says the tabs need unlocking well within 30 s |
| `browser_close_spares_owner_tabs` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionCloseCTests.closingClaudesPageClosesOnlyItAndNamesLatchkeysOwnBrowser | browser_act close with Claude's page closes only that page, runs no Safari tab close, owner tabs (LinkedIn) all stay; the agent's own wrong choice of tab can't be tested |
| `browser_answer_names_browser_and_lock` | test | macos/Tests/BrowserOwnerTabTests.swift › BrowserOwnerTabToolTests.answersFromLatchkeysOwnBrowserSaySo; relay/internal/mcpserver/messages_test.go › TestStatusLine (FR-671 locked/unlocked lines) | Both halves of fix ec0656d have tests in that commit |
| `browser_script_error_detail` | test | macos/Tests/BrowserActionTests.swift › LockedBrowserActionTests.scriptsAwaitAndSayWhatFailed; PageActionScriptTests.scriptsRunWhereThePageForbidsEval | await and 'lk-check-boom' in Latchkey's own browser, error text through Safari's async route |
| `browser_script_on_strict_csp` | test | macos/Tests/BrowserActionTests.swift › PageActionScriptTests.scriptsRunWhereThePageForbidsEval | A CSP page without unsafe-eval: eval refused, the spliced async route returns the value (Trusted Types itself not reproduced) |
| `browser_slow_site_no_lost_page` | test + Toni's conditions | macos/Tests/RegressionBrowserCTests.swift › RegressionLoadingCTests.aSlowPageAnswersInTimeSaysItIsStillLoadingAndStaysOpen | A local server that never finishes the page: answer within 30 s, says still loading (2026-11-16 fix had no test), page still readable; the real site's speed can't be reproduced; takes ~23 s |
| `browser_failed_load_not_old_page` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionLoadingCTests.aPageThatDoesntLoadIsAnErrorNotTheOldPage | A refused 127.0.0.1 port after Example Domain: an error saying it didn't load, not the old text (fb384f8's Safari-window half is obsolete: pages are Latchkey's own) |
| `browser_back_no_cancel_error` | test + Toni's conditions | macos/Tests/RegressionBrowserCTests.swift › RegressionLoadingCTests.goingBackAnswersWithThePageAndNoCancelError | Back after a click on a served page answers the first page with no error; whether WebKit emits -999 on that back is WebKit's, and the locked/lid-closed run is the owner's |
| `browser_locked_close_names_own_browser` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionCloseCTests.closingClaudesPageClosesOnlyItAndNamesLatchkeysOwnBrowser (locked: true) | Fix 87b54d3 had no test: the close answer names Latchkey's own browser and never Safari, locked and unlocked |
| `browser_refuses_other_schemes` | test | macos/Tests/BrowserTests.swift › BrowserToolTests.refusesAddressesThatArentWebPages | file:, javascript:, data: and others refused with the http message through browser_open and browser_read, no page opened |
| `browser_password_value_hidden` | test | macos/Tests/BrowserTests.swift › PageScriptTests.neverReturnsWhatSecretFieldsHold | Password, one-time-code and card values never in the read (fix df1e803) |
| `logins_masked_field_and_real_error` | test | macos/Tests/RegressionLoginsCTests.swift › RegressionLoginsCTests.aMaskThatKeepsOnlyKeyPressesHoldsTheUserNameAndNoTryIsCounted | A Citi-like mask that cuts a value set in one go to two letters keeps the key-by-key user ID; three turned-away passwords are each typed and pressed (no counting, no block); Citi's real mask is the site's |
| `setup_ask_now_says_what_is_off` | test + sandbox check `setup-names-what-is-off` | macos/Tests/RegressionSeamsTests.swift › appsTurnedOffEarlierAreNamedWithWhereToTurnThemOn | setup's note for apps turned off earlier is tested; macOS's own questions and System Settings opening need the real Mac |
| `logins_texted_code_live` | none | none: it is the tool's description, which no test pins (Toni, 2026-11-26) | The tools present and the description wording the case checks; the older live failures (boxes, focus, Backspace) are in SignInFillTests |
| `logins_checkbox_page_not_signed_in` | test | macos/Tests/SignInFillTests.swift › typesTheUserNameThenThePasswordAndPressesTheButtonClaudeNamed | logins_sign_in is gone (no logins_sign_in tool), and a fill's answer is the page and never 'Signed in' |
| `logins_code_delivery_step` | test | macos/Tests/RegressionLoginsCTests.swift › RegressionLoginsCTests.aPasswordNeverGoesIntoACodeBoxAndTextMeIsNeverPressed; macos/Tests/SignInFillTests.swift › aCodeClaudeReadGoesAcrossTheBoxesAndClaudeIsToldToCleanUp | A password into Citi's one-character password box is refused and nothing typed; Text me / Call me are never pressed; the six boxes in one fill was already tested |
| `browser_claudes_safari_tab_after_redirect` | test + sandbox check `safari` | macos/Tests/BrowserTabTests.swift › OwnerTabNavigationTests.claudesOwnTabIsUsedAfterTheSiteSendsItOn, claudesOwnTabSurvivesARedirect | A tab of Claude's redirected after the load limit is found and read again twice; the no-extra-tab part needs the owner's Safari |
| `logins_hidden_ad_frame_not_a_check` | test | macos/Tests/RegressionLoginsCTests.swift › RegressionLoginsCTests.aHiddenAdFrameIsNoCheckInTheAnswer | The signed-in page with a hidden frame from its ad script answers with the page, no error and no 'check' claim |
| `logins_code_finder_busy_runner` | test | macos/Tests/CodeFinderTests.swift (the three code lookup tests) | a test-only issue (#42): the tests themselves run on every mac build and fail again if their read limit is short |
| `logins_find_says_codes` | test | macos/Tests/SignInToolsTests.swift › SignInToolsTests.findListsSitesAndUserNamesNeverSecrets | Totals and 'none has a verification code', also with no sign-ins |
| `logins_other_site_gets_nothing` | test | macos/Tests/SignInFillTests.swift › noSignInForTheSiteSeveralUserNamesAndHttpsOnly, aPageCantClaimAnotherSitesAddress; macos/Tests/SignInDataTests.swift › sharedHostsFillOnlyThemselves | No sign-in for another site, a page can't pose as another, shared hosts fill only themselves |
| `browser_url_never_reuses_another_chats_page` | test | macos/Tests/OwnPagesTests.swift › OwnPagesToolTests.aURLWithoutPageNeverLoadsIntoAnotherChatsSafariPage | Added with the fix (884ac73): url without page opens a new page, the other chat's tab untouched |
| `browser_owner_tab_turns` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionOwnerTabTurnsCTests.aCallNamingAnOwnersTabWaitsForTheOtherCallsTurn, aTurnThatDoesntComeSaysAnotherChatIsWorking | OneAtATimeTests/TakingTurnsTests test the gate alone; nothing checked the tab calls take it: now a held turn keeps a call from picking or running in the tab, and it says another chat is working |
| `browser_page_limit_oldest_idle_gives_way` | test | macos/Tests/OwnPagesTests.swift › OwnPagesTests.theOldestIdlePageGivesWayWhenAllAreOpen | At the limit the page idle 5 minutes gives way; one used within 5 minutes refuses |
| `browser_safari_script_await_and_iife` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionSafariScriptCTests (safarisScriptsNeverUseThePagesEval, anUndefinedResultIsReadAsEmpty, theAsyncRouteRunsWhereThePageReplacedEval, latchkeysOwnBrowserRunsWhereThePageReplacedEval) | await and async-arrow values were covered (scriptsRunWhereThePageForbidsEval); never-through-eval (Amex) and the unset theAnswer (-2753) weren't |
| `browser_url_with_screenshot` | test | macos/Tests/OwnPagesTests.swift › OwnPagesToolTests.aURLWithScreenshotGivesThePicture | url with screenshot answers an image, one page opened |
| `browser_frames_and_hrefless_links` | test | macos/Tests/BrowserActionTests.swift › PageActionScriptTests.hreflessLinksAndSameSiteFramesAreListed, anOpenMenusItemsComeFirst | Same-site frame fields, href-less Sign Off, an open menu's items first; Chase's real page is the site's |
| `browser_type_submit_rich_editor` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionRichEditorCTests.typingWithSubmitIntoARichEditorSendsTheText | A contenteditable editor that keeps its own copy from typing's input events sends 'Helsinki' on submit (Wikipedia's form field case is in PageScriptTests.clicksTypesChoosesAndSubmits) |
| `browser_hover_says_what_it_did` | test | macos/Tests/RegressionBrowserCTests.swift › RegressionHoverCTests.aHoverWhoseMenuDrawsLateDoesntSayNothingShows | A menu drawn 300 ms after hover: the answer lists its items and never says 'nothing new shows' |
| `browser_safari_text_composed` | test + sandbox check `safari` | macos/Tests/RegressionComposedTextTests.swift › aProgramGetsItsArgumentsAsGiven, anAppleScriptGetsTheTextAsGiven, aShellCommandsTextIsAsGiven, aCommandWritesInAFolderWithAccents | Added with the fix (#56): every program Latchkey starts gets its text as given, not decomposed; a real Safari tab of Claude's is the sandbox check's |
| `browser_procare_role_choice` | test + Toni's conditions | macos/Tests/RegressionRealInputTests.swift › theRoleChoiceIsListedClickedForRealAndTheSignInGoesThrough (and the rest of the suite) | Added with the fix (#51): boxes that look clickable are listed, and Latchkey's own browser clicks and types as a real mouse and keyboard; Procare's own page is a real site |

## Regressions: shell (`regressions-shell`)

| Case | Covered by | Test | Why |
|---|---|---|---|
| `shell_zsh_heredoc` | test | macos/Tests/LeftoversTests.swift › zshHereDocumentsWorkInsideTheFence | Runs the case's here-document and =(...) inside the real fence; fails without TMPPREFIX (30f9a8b/281197d) |
| `shell_program_stopped_by_macos_named` | test | macos/Tests/StoppedProgramsTests.swift › findsTheProgramItsSignalAndWhy (+4 more); macos/Tests/LeftoversTests.swift › aProgramStoppedByMacOSIsToldOnce | Crash-report parsing and the note in the next answer are tested with a planted report; macOS writing a real report isn't (and must not be triggered) |
| `shell_unified_log_readable_or_said` | test | macos/Tests/RegressionShellATests.swift › aRefusedSystemLogInTheOutputPointsToLatchkeysOwn; logShowPrintsLinesOrTheAnswerSaysWhyNot | SystemLogHintTests only checked the pure function; the new test fails if ShellCapability.result stops adding the hint (fcca288), and runs the case's real log show in the fence |
| `shell_background_leftovers_stopped` | test | macos/Tests/LeftoversTests.swift › aFinishedCommandLeavesNothingRunning; aQuickDoubleForkIsStoppedToo; aProcessThatLeftTheTerminalIsStoppedToo | Background, nohup-style and double-forked leftovers are checked gone after the command and the Left behind line checked |
| `shell_stop_just_started` | test | macos/Tests/LeftoversTests.swift › aJobStoppedAtOnceLeavesNoShell | Stops five jobs right after start (wait 0) and checks no process of theirs is left (9e52ac3, 4528d0f) |
| `shell_job_found_while_running` | test | macos/Tests/RegressionShellATests.swift › aRunningJobIsFoundByCheckInputAndStop | No fix commit found for the 2026-11-02 report; the new test does the case's check, input and stop on three running jobs through the public tools and fails on any "There's no job" |
| `shell_ps_top_run` | test | macos/Tests/LeftoversTests.swift › everydayToolsWorkInsideTheFence | ps and top run inside the fence (8ca2cb3) |
| `shell_fontd_survives` | test | macos/Tests/LeftoversTests.swift › aSandboxThatRefusesFilesButNotFoldersIsLeftAlone | A sandbox like fontd's (refuses files, not folders) survives a command (f5faeb8) |
| `shell_huge_output_no_crash` | test | macos/Tests/ShellTests.swift › outputOverTheKeptMegabyteIsRead | 2.5 MB of output read past the dropped megabyte, added with the fix cecebd3 |
| `shell_xcode_build_in_fence` | test | macos/Tests/ShellTests.swift › FencedBuildTests (swiftBuildsAPackageInsideTheFence, xcodebuildBuildsAPackageInsideTheFence, buildToolsAreFoundFromScriptsToo) | SwiftPM, the compiler's macro sandbox and xcodebuild build inside the real fence without sandbox_apply; cloning the GitHub repo itself isn't done in tests |
| `shell_otos_builds_in_fence` | test | macos/Tests/ShellTests.swift › buildToolsAreFoundFromScriptsToo; eachJobHasItsOwnAssetCatalogDaemon; anIconComposerIconAsksForOpen | Task sandbox off, a per-job ibtoold pool and the Icon Composer hint are tested; building Otos itself needs the owner's repo |
| `shell_xcode_tests_in_fence` | test | macos/Tests/ShellTests.swift › xcodebuildTestBuildsInsideAndTestsThroughTheLauncher; onlyTheTestLauncherLeavesTheFenceAndOnlyWithOpen; theLauncherRunsOnlyTheTestStep | Build inside, test step through the launcher, EXIT 64 with the uses-open hint without open (FR-335) |
| `shell_big_scratch_deleted` | test | macos/Tests/LeftoversTests.swift › aBigScratchFolderIsDeletedNotTrashed | Over the limit is deleted, under it trashed, and the answer says deleted |
| `shell_headless_chrome_profile` | sandbox check `headless-chrome-profile` | none: it is the tool's description, which no test pins (Toni, 2026-11-26) | shell_run's description says headless Chrome needs --user-data-dir in the scratch folder; Chrome's print-to-PDF itself is the sandbox check's |

## Regressions: computer control (`regressions-computer`)

| Case | Covered by | Test | Why |
|---|---|---|---|
| `computer_type_without_ref_names_focus` | test + sandbox check `computer` | macos/Tests/ComputerFormTests.swift › typingWithoutARefSaysWhereTheKeysWent | Typing without ref names the focused element (30f9a8b); real Calculator needs the unlocked Mac |
| `computer_press_reports_changes` | test + sandbox check `computer` | macos/Tests/ComputerFormTests.swift › whatElseChangedIsTold | A press names other values that changed (30f9a8b); real Calculator needs the unlocked Mac |
| `computer_ui_list_cut_said` | test | macos/Tests/ComputerFormTests.swift › aLongWindowIsListedInPartsFromOneLook; AppListingTests › repeatedLabelTextIsLeftOut; aCutWalkIsSaid | 300 per page with "after", match, repeats left out, a cut walk said (FR-511 to FR-514) |
| `computer_cold_app_full_tree` | test | macos/Tests/ComputerFormTests.swift › aFirstLookWithOnlyTheTitleBarLooksAgain | A title-bar-only first look wakes the app and looks again (0.8.107/0.8.108) |
| `computer_display_asleep_not_lid_closed` | test | macos/Tests/ComputerTests.swift › aSleepingDisplayOutOfTheActiveListIsAsleepNotLidClosed | Connected but not active is called asleep, not lid closed (0278ee2) |
| `computer_never_targets_latchkey` | test | macos/Tests/RegressionComputerATests.swift › latchkeyIsRefusedForEveryLookAndAction; theRunningLatchkeyIsNeverFound | ComputerSelfTests checked only the name function; the new test fails if the tools' refusal is removed (looks and actions reach the stand-in), and checks the running test build is never found |
| `computer_press_selects_sidebar_row` | test + sandbox check `computer-sidebar-row` | macos/Tests/RegressionSeamsTests.swift › aPressOnARowItsCellOrItsTextSelectsTheRow | which presses select the row is tested; selecting another app's real row needs its window and Accessibility, unlocked |
| `computer_window_buttons_named` | test + sandbox check `computer-window-buttons` | macos/Tests/RegressionSeamsTests.swift › windowButtonsWithoutATitleAreNamedByTheirKind | the naming rule is tested; reading a real window's buttons needs another app's window and Accessibility, unlocked |

## Regressions: other capabilities (`regressions-other`)

| Case | Covered by | Test | Why |
|---|---|---|---|
| `log_category_per_machine` | test | relay/internal/mcpserver/machines_test.go › TestMergedToolsPerKindNotes | Added with fix 8a51710: asserts "(trash: Mac only; delete: Linux servers only)" in the united option's description; the Mac answering category connection is ordinary latchkey_log behavior |
| `files_cloud_only_read` | test + Toni's conditions | macos/Tests/CloudFileTests.swift › coordinationDownloadsIt, aRefusedCoordinationFallsBackToTheRequest, whenEverythingFailsTheCodesSayWhy | Download by file coordination first, then the old request, and the failure carries the codes; a real provider's cloud-only file stays manual |
| `files_own_files_protected` | test | macos/Tests/OwnFilesTests.swift › writesAndEditsAreRefused, otherSpellingsOfThePathAreRefused, theAppProtectsItsRealFiles | Writes into Application Support/Latchkey are refused, other spellings of the path too |
| `notes_delete_saved` | test + sandbox check `notes` + Toni's conditions | macos/Tests/NotesWriteTests.swift › deletesToRecentlyDeleted, deletesAFolder, aNoteNotesHasntSavedAsDeletedIsSaidSo, aFolderStillInNotesDatabaseIsNotSaidDeleted | Fix a7464ad (move into Recently Deleted, with its id passed to the script) is asserted; whether real Notes then saves at once, locked too, needs real Notes |
| `notes_unknown_id_plain` | test | macos/Tests/RegressionOtherDTests.swift › aNoteIdNotesNoLongerHasIsSaidPlainly | notes_read and notes_change (append, rename, move, delete) on a gone x-coredata id answer "There is no note with id … notes_find", never -1728, and never ask Notes' scripting (which here would throw the raw -1728 error) |
| `calendar_repeat_said` | test | macos/Tests/RegressionOtherDTests.swift › makingAnEventRepeatIsSaidInTheAnswer, theRepeatPhraseNamesFrequencyAndCount | Only create's answer was tested; now update with repeat daily, repeat_count 3 must say ", repeats every day, 3 times" and turning it off "no longer repeats" (fix 4116924) |
| `contacts_id_changes_after_icloud` | test | macos/Tests/ContactsPlacesTests.swift › aNewCardWhoseIdChangedIsFoundAgain | After iCloud changes the id, update and delete by the old id still work (ContactsMemory) |
| `contacts_group_removal_sticks` | Toni's conditions | none | Fix 1a22092 is in CNContactsBackend against the real Contacts store (iCloud's linked records); tests may not touch real Contacts. The memory side ("taken out by Claude stays out") is in ContactsPlacesTests › aMembershipICloudDroppedIsPutBack |
| `contacts_quick_group_delete_no_icloud_copy` | test | macos/Tests/ContactsPlacesTests.swift › deletingANewGroupDeletesICloudsCopy, aCopyThatAppearsAMomentLaterIsDeletedToo, aLaterCopyDeletionIsInTheActivity | iCloud's copy of a just-made group is deleted, also when it turns up a moment or a change later |
| `maps_directions_by_place_names` | test + sandbox check `maps` | macos/Tests/ContactsPlacesTests.swift › directionsToAPlaceByName | A destination the geocoder can't place is searched as a place name; Apple's real answer for SFO stays manual |
| `whatsapp_group_sender_names` | test | macos/Tests/WhatsAppStoreTests.swift › encodedMemberFieldsAreNotNames, aSenderWithoutANameIsSaidSo, messagesHaveSendersKindsAndNoGroupEvents | «+IAE=» is never a name; a sender with no name is said in words |
| `whatsapp_mentions_named` | test | macos/Tests/WhatsAppStoreTests.swift › mentionsShowThePerson | "@247179730018527" becomes a name, a +number, or a member-without-name phrase |
| `whatsapp_no_double_messages` | test | macos/Tests/WhatsAppStoreTests.swift › aMessageStoredTwiceIsReadOnce | Two rows with one id in one chat are read once |
| `removed_tools_stay_removed` | test | WhatsAppToolsTests › onlyFindingAndReading; RemindersExtrasTests › flagsTagsSubtasksAndSectionsAreRefused | Exact tool set: no mail_change/send/queue, whatsapp_send/link, messages_change; reminders setters refused. The set does hold mail_find, mail_read, mail_archive again (spec 013), which contradicts this case's steps |
| `never_disturb_front_app` | test + sandbox check `front-app-unchanged` + eval task `notes.add-to-shopping-list` | macos/Tests/RegressionOtherDTests.swift › backgroundScriptsNeverBringAnAppForward, backgroundCapabilitiesHaveNoWindowCode | Checks that Notes, Messages, and Mail scripts never activate, type, or use the clipboard, and that background capabilities' code has no window, keyboard, pointer, or pasteboard calls; the front app staying the same needs the unlocked Mac |
| `never_disturb_no_permission_prompts` | test + sandbox check `no-permission-prompts` | macos/Tests/RegressionSeamsTests.swift › aScriptForAnAppMacOSHasntAskedAboutIsNeverRun | a script for an app macOS hasn't asked about is refused before osascript runs; that no prompt shows needs macOS's privacy system |
| `machines_keep_awake_real` | test + sandbox check `keep-awake-real` | macos/Tests/HelperSigningTests.swift › FileStampTests.tellsAReplacedFileFromTheSameOne; KeepAwakePolicyTests › helperUnavailable | The helper notices its replaced file (0.8.19 root cause); SleepDisabled really being 1 needs the Mac |
| `machines_versions_shown` | test | relay/internal/mcpserver/machines_test.go › TestMachinesResult; machines_e2e_test.go › TestTwoMachinesBehindOneConnector | Each line has kind, Latchkey version, OS version, online/offline |
| `machines_single_copy_online` | test | macos/Tests/SingleCopyTests.swift › anotherThatStaysMakesThisOneQuit, aCopyHandingOverIsWaitedFor; ReconnectPolicyTests | Fix e5f0ab4's tests: a second copy quits, and a replaced connection reconnects |
| `machines_audit_all_match` | test | linux/internal/agent/regression_d_test.go › TestRegressionDAuditCountsTheLogsFirstCall (plus existing macos/Tests/CutOffCallsTests.swift › aCallAnOlderAppsQuitCutOffIsToldApart) | Mac half was covered; the Linux check's wiring (asking from before the log's first call, FromLogStart) wasn't, since activity_test tests only the helpers. Seen failing with either line of 22f2b1f reverted |
| `machines_text_results_with_state_line` | test | macos/Tests/RegressionOtherDTests.swift › everyResultSentToTheRelayIsTextOnly (plus existing relay/internal/mcpserver/messages_test.go › TestStatusLineStartsOnItsOwnLine) | The state line on its own line was covered; the Mac sending structuredContent: nil (fix 76f368d) wasn't. A source check requires every CallResult the app builds to set structuredContent: nil |
| `relay_bad_numbers_refused` | test | macos/Tests/RegressionOtherDTests.swift › aBadLimitIsAnErrorAboutTheNumber (plus existing ArgumentTests) | Existing tests used 1e19, NaN, and infinity only; now the case's -1 and 1.5 through notes_search and notes_find give an error about limit and no notes. Not crashing is implied |
| `linux_machine_name_required` | test | relay/internal/mcpserver/machines_test.go › TestChooseMachine; machines_e2e_test.go › TestTwoMachinesBehindOneConnector | No machine is refused naming both machines and their state; named, it runs there |
| `linux_leftovers_stopped` | test | linux/internal/shell/shell_linux_test.go › TestLeftoversAreStopped, TestSudoLeftoversAreStopped | Background leftovers, sudo's too, are stopped when the command ends (cgroups) |
| `contacts_membership_survives_icloud` | test | macos/Tests/ContactsPlacesTests.swift › aMembershipICloudDroppedIsPutBack | iCloud takes over card and group with new ids and drops the membership; Latchkey puts it back |
| `passwords_export_reaches_save_panel` | Toni's conditions | none | Drives the real Passwords app and its save panel through Accessibility (private helpers in PasswordsExport.swift); only the owner starts an export |
| `passwords_export_leaves_no_file` | test | macos/Tests/PasswordsExportCleanupTests.swift › aFileSavedElsewhereIsWiped, aFileSavedAfterTheStopIsWipedWhenItTurnsUp | A stray Passwords-XXXXXXXX.csv in Downloads, Desktop, Documents, home, or cloud folders is wiped, also when saved after the stop |
| `feedback_tool_offered` | test | relay/internal/mcpserver/regression_d_test.go › TestRegressionDFeedbackWhileNoMachineIsOnline | With the Mac offline the tool is still listed, and summary "" is refused with "Give a summary" and nothing queued. Seen failing when sharing counts only online machines |
| `maps_near_only_nearby` | test + sandbox check `maps` | macos/Tests/ContactsPlacesTests.swift › withNearOnlyNearbyPlaces | With near, a place over 50 km away is left out and "within 50 km of" is said; real Apple results stay manual |
| `feedback_tool_only_when_shared` | test | relay/internal/mcpserver/feedback_test.go › TestSharedReportsReachTheIntakeSealed, TestTheOperatorsBlockOffersNoTool | No tool until the Mac says it shares; tool gone when sharing goes off |
| `feedback_reaches_the_developer` | test | relay/internal/mcpserver/feedback_test.go › TestSharedReportsReachTheIntakeSealed (wording "encrypted and queued" also in regression_d_test.go › TestRegressionDFeedbackWhileNoMachineIsOnline) | Sealed to the developer's key, opens with the fields, no email, and the answer doesn't repeat the details |
| `maps_not_searched_is_not_nothing_found` | test + sandbox check `maps` | macos/Tests/PlacesFailureTests.swift › onlyNotFoundIsNothingFound, aLimitedSearchSaysSoAndIsNotNothingFound, otherErrorsSayWhatHappened | Only MapKit's not-found is 'found nothing'; a limited search says so; Apple Maps' real answers are the sandbox check's |

## Use cases (the former use-case groups)

Each capability's everyday cases, last tried by hand in each screen state in 2026-11 (the
results are in `docs/use-cases.md`). "test (`e2e mac` x)" is `relay/cmd/e2e mac`'s check `x`,
which runs the app's real tools on GitHub's Mac runner for every pull request that changes
them. Every use case while locked or with the lid closed is Toni's conditions
(`docs/screen-states.md`).

| Case | What | Covered by |
|---|---|---|
| **Notes** | | |
| `notes.folders` | List folders and recent notes | sandbox check `notes` |
| `notes.search` | Search notes | sandbox check `notes` |
| `notes.read` | Read a note | sandbox check `notes` |
| `notes.create_in_folder` | Create a note in a chosen folder | sandbox check `notes` |
| `notes.create` | Create a note in the default folder | sandbox check `notes` |
| `notes.append` | Add text to the end of a note | sandbox check `notes` |
| `notes.edit` | Change one passage in a note | sandbox check `notes` |
| `notes.replace` | Replace a note's text | sandbox check `notes` |
| `notes.rename` | Rename a note | sandbox check `notes` |
| `notes.create_folder` | Create a folder | sandbox check `notes` |
| `notes.move` | Move a note to another folder | sandbox check `notes` |
| `notes.create_in_new_folder` | Create a note in a folder that doesn't exist yet | sandbox check `notes` |
| `notes.delete` | Delete a note | sandbox check `notes` |
| `notes.delete_folder` | Delete a folder | sandbox check `notes` |
| `notes.checklist_create` | Create a note with a real checklist | sandbox check `notes` |
| `notes.checklist_delete` | Delete the checklist note | sandbox check `notes` |
| **Messages** | | |
| `messages.conversations` | List recent conversations | sandbox check `messages` + Toni's conditions |
| `messages.search` | Search all messages | sandbox check `messages` + Toni's conditions |
| `messages.read` | Read a conversation | sandbox check `messages` + Toni's conditions |
| **Files** | | |
| `files.list` | List a folder | test (`e2e mac` files) + sandbox check `files` |
| `files.search` | Search with Spotlight | sandbox check `files` |
| `files.create_folder` | Create a folder | sandbox check `files` |
| `files.write` | Write a new file | test (`e2e mac` files) + sandbox check `files` |
| `files.append` | Add to a file | sandbox check `files` |
| `files.edit` | Change one passage in a file | test (`e2e mac` files) + sandbox check `files` |
| `files.read` | Read a text file | test (`e2e mac` files) + sandbox check `files` |
| `files.details` | See a file's details | sandbox check `files` |
| `files.copy` | Copy a file | sandbox check `files` |
| `files.move` | Move or rename a file | sandbox check `files` |
| `files.read_pdf` | Read a PDF | sandbox check `files` |
| `files.read_image` | See an image | test (`e2e mac` files) + sandbox check `files` |
| `files.trash` | Move to the Trash | test (`e2e mac` files) + sandbox check `files` |
| **Shell** | | |
| `shell.run` | Run a command | test (`e2e mac` shell) + sandbox check `shell` |
| `shell.long` | Run a long command and check on it | test (`e2e mac` shell) + sandbox check `shell` |
| `shell.input` | Type into a running command | sandbox check `shell` |
| `shell.stop` | Stop a running command | sandbox check `shell` |
| `shell.list_jobs` | List running commands | sandbox check `shell` |
| `shell.write_declared` | Write outside the allowed places (declared) | sandbox check `shell` |
| `shell.local_network` | Reach a device on the home network | sandbox check `shell` |
| `shell.internet` | Reach the internet | sandbox check `shell` |
| `shell.open` | Open an app through macOS | sandbox check `shell` |
| **Browser** | | |
| `browser.open` | Open a page | test (`e2e mac` browser) + sandbox check `browser` |
| `browser.read` | Read the page showing | sandbox check `browser` |
| `browser.click` | Click a link on the same site | test (`e2e mac` browser) + sandbox check `browser` |
| `browser.back` | Go back | sandbox check `browser` |
| `browser.script` | Run JavaScript in the page | sandbox check `browser` |
| `browser.click_other_site` | Click a link to another site | sandbox check `browser` |
| `browser.type` | Type into a field and submit | test (`e2e mac` browser) + sandbox check `browser` |
| `browser.widgets` | Set up test widgets on a harmless page | sandbox check `browser` |
| `browser.key` | Press keys in the page | sandbox check `browser` |
| `browser.select` | Choose from a dropdown | sandbox check `browser` |
| `browser.hover` | Hover to open a menu | sandbox check `browser` |
| `browser.scroll` | Scroll the page and inside an element | sandbox check `browser` |
| `browser.upload` | Attach a file from the Mac to the page | sandbox check `browser` |
| `browser.download` | Save a linked file to Downloads | test (`e2e mac` browser) + sandbox check `browser` + eval task `browser.download-statement` |
| `browser.download_pdf` | Save the PDF a tab shows | sandbox check `browser` |
| `browser.dialog` | Answer a page's confirm dialog | sandbox check `browser` |
| `browser.tabs` | List tabs | sandbox check `browser` + sandbox check `safari` |
| `browser.screenshot` | Screenshot of the page | sandbox check `browser` |
| `browser.close` | Close Claude's pages | sandbox check `browser` |
| **Sign-in** | | |
| `logins.list` | List the sites Latchkey can sign in to | sandbox check `logins` |
| `logins.sign_in` | Sign in on a page with a saved password | sandbox check `logins` |
| `logins.own_session_kept` | A site Latchkey holds a password for is signed in with Latchkey's own session, never a copy of Safari's, and stays signed in on the next page | Toni's conditions |
| `logins.texted_code_deleted` | A code a site texted was used by Latchkey and the text deleted in Messages afterwards | Toni's conditions |
| `logins.other_site` | A page of a site with no saved sign-in gets nothing | sandbox check `logins` |
| `logins.import_folder_unreadable` | Claude can't read the folder where the Passwords export lands | sandbox check `logins` |
| **Computer control** | | |
| `computer.screenshot` | See the screen | sandbox check `computer` |
| `computer.ui` | Read the front window's buttons and text | sandbox check `computer` |
| `computer.apps` | List running apps | sandbox check `computer` |
| `computer.key` | Press a key | sandbox check `computer` |
| **Calendar** | | |
| `calendar.overview` | List calendars and the week ahead | sandbox check `calendar` |
| `calendar.search` | Search events | sandbox check `calendar` |
| `calendar.free` | Find free time | sandbox check `calendar` |
| `calendar.create` | Create an event with an alert | sandbox check `calendar` |
| `calendar.read` | Read an event in full | sandbox check `calendar` |
| `calendar.move` | Move an event | sandbox check `calendar` |
| `calendar.repeat` | Make an event repeat | sandbox check `calendar` |
| `calendar.delete` | Delete an event | sandbox check `calendar` |
| `calendar.invitation_read` | See your answer to an invitation | Toni's conditions |
| `calendar.invite_own` | Inviting the calendar's own address is refused | Toni's conditions |
| **Reminders** | | |
| `reminders.overview` | List lists and open reminders | sandbox check `reminders` |
| `reminders.create_list` | Create a list | sandbox check `reminders` |
| `reminders.create` | Create a reminder with a due time | sandbox check `reminders` + eval task `reminders.passport-due` |
| `reminders.update` | Change a reminder | sandbox check `reminders` + eval task `reminders.complete-stamps` |
| `reminders.complete` | Complete and reopen | sandbox check `reminders` |
| `reminders.completed` | List completed reminders | sandbox check `reminders` |
| `reminders.delete` | Delete a reminder | sandbox check `reminders` |
| `reminders.delete_list` | Delete a list | sandbox check `reminders` |
| **Contacts** | | |
| `contacts.overview` | List groups and count | sandbox check `contacts` |
| `contacts.search` | Search contacts | sandbox check `contacts` |
| `contacts.read` | Read a card in full | sandbox check `contacts` |
| `contacts.create` | Create a card | sandbox check `contacts` |
| `contacts.update` | Change a card | sandbox check `contacts` |
| `contacts.create_group` | Create a group | sandbox check `contacts` |
| `contacts.add_to_group` | Add a card to a group | sandbox check `contacts` |
| `contacts.remove_from_group` | Remove a card from a group | sandbox check `contacts` |
| `contacts.rename_group` | Rename a group | sandbox check `contacts` |
| `contacts.delete_group` | Delete a group | sandbox check `contacts` |
| `contacts.delete` | Delete a card | sandbox check `contacts` |
| **Location & Maps** | | |
| `location.read` | Where the Mac is | Toni's conditions |
| `maps.places` | Find places nearby | sandbox check `maps` |
| `maps.directions` | Directions and driving time | sandbox check `maps` |
| `maps.transit` | Transit time | sandbox check `maps` |
| `maps.address` | Look up an address | sandbox check `maps` |
| `maps.reverse` | Name a place from coordinates | sandbox check `maps` |
| **WhatsApp** | | |
| `whatsapp.chats` | List recent chats | Toni's conditions |
| `whatsapp.search` | Search messages | Toni's conditions |
| `whatsapp.read` | Read a chat, with message ids | Toni's conditions |
| **Nothing left behind** | | |
| `sweep.notes` | No test notes or folders left | sandbox check `sweep` |
| `sweep.contacts` | No test cards or groups left | sandbox check `sweep` |
| `sweep.calendar` | No test events left | sandbox check `sweep` |
| `sweep.reminders` | No test reminders or lists left | sandbox check `sweep` |
| `sweep.files` | No test files left | sandbox check `sweep` |
| `sweep.browser` | Claude's own Safari page closed | sandbox check `sweep` |

## Found by the sandbox Mac (2026-11-26, its first runs)

Issues in Latchkey that only the installed app against real Mac apps showed (spec 016 T16).
Issues in the sandbox's own scripts and checks are listed in `specs/016-test-strategy/research.md`
§7.

| Case | Covered by | Test | Why |
|---|---|---|---|
| `mcp_behind_a_local_proxy` | test + sandbox check `tools` | relay/internal/mcpserver/host_test.go › TestLoopbackRequestsMayNameTheRelaysOwnHost | The MCP SDK's DNS rebinding guard refused every call that reached the relay through a proxy on the same machine (the sandbox's; a relay outside Docker behind Caddy); the relay's own public host is allowed now, any other host still refused |
| `safari_claudes_tab_not_called_owners` | test + sandbox check `safari` | macos/Tests/BrowserOwnerTabTests.swift › aTabOfClaudesThatWentOffIsNotCalledTheOwners | A tab of Claude's own lost after an action was reported as "the owner's Safari tab" |
| `traces_delete_races_a_writer` | test | relay/internal/trace/trace_test.go › TestADeletedAccountsFolderGetsNoNewDayFile, TestDeleteSucceedsWhileAnotherProcessWritesTheAccount | Found by CI on this work's pull request: a writer kept adding day files to a deleted account's folder while another process deleted it |
| `contacts_card_with_note_unchangeable` | test + sandbox check `contacts-card-with-note` | macos/Tests/ContactsPlacesTests.swift › aCardWithANoteIsChangedThroughTheContactsApp, aCardWithANoteWithoutControlSaysWhatToAllow, theScriptsNeverStartContactsThemselves, theContactsAppGetsEveryField, theNoteRefusalIsRecognized (spec 007 FR-722a, fixed 2026-11-27) | Every update of a card that has a note failed with Cocoa error 134092: macOS lets only apps with Apple's Contacts notes entitlement change such a card (Apple Developer Forums, FB23452026). Such a card now goes through the Contacts app's scripting, started hidden and quit again (Toni: "Via Contacts' scripting"); the sandbox check changes a job title, a phone and a yearless birthday, keeps the note, deletes the card, and finds Contacts quit, with the screen sampler running |
| `safari_lost_tab_still_listed` | test + sandbox check `safari-script-navigation` | macos/Tests/RegressionBrowserBTests.swift › aSafariPageWhoseTabWasLostLeavesTheList | Found by the new sandbox check (2026-11-27): after a script sent Claude's Safari tab to another site, Latchkey said "That page isn't open", yet the tab list kept naming it Claude's page with its old address (a page was forgotten only when closed). A call that loses the tab now forgets the page |
| `safari_busy_right_after_pick` | test + sandbox check `safari-busy-tab` | macos/Tests/BrowserDialogTests.swift › aTabBusyRightAfterThePickIsSaidBusyNotGone | Found by the new sandbox check (2026-11-27): an owner's tab whose page turned busy right after Claude picked it was answered "isn't where it was (it was closed…)" after about 16 s, once past the relay's 30 s: the pick never noted the window's tabs with the mark seen, which is what lets a tab that answers no script be recognised. The pick now notes them; the tab is said busy (26.9 s in the sandbox, within the relay's 30 s) |
| `safari_busy_tab_past_the_deadline` | test + sandbox check `safari-busy-tab` | macos/Tests/BrowserDialogTests.swift › aTabBusyAtThePickIsSaidBusyAtOnce | Found by the full sandbox run on a fresh copy (2026-11-27): a tab already busy when Claude picked it cost 10 s at the pick and 10 s more at the look, so on a busy Mac the answer came after the relay's 30 s. The pick now says it is busy at once and leaves it picked |
| `sandbox_first_app_starts` | sandbox (image) | macos/scripts/eval-image.sh starts each app Latchkey drives once, hidden | A fresh copy's first run counted macOS's first-start questions of Apple's apps ("'Mail' Notifications") as Latchkey's permission prompts, and Contacts' first start timed out the card-with-note check (2026-11-27) |
| `evals_client_per_try` | test | relay/internal/e2e/client_test.go › TestAClientIsRegisteredOncePerRelay, TestARefusedRegistrationSaysItsStatus | The first local eval runs (2026-11-27): every try after the twelfth failed with "registration failed" before Claude Code started: the harness registered an OAuth client for each of the 60 tries, and the relay registers 10 at once, then one a minute per address. One client per relay now |
| `contacts_app_started_shown_by_its_script` | test + sandbox check `contacts-card-with-note` | macos/Tests/ContactsPlacesTests.swift › theScriptsNeverStartContactsThemselves | Found in the sandbox while fixing the row above (2026-11-27): right after the check had quit Contacts, Latchkey's change left a Contacts running that it hadn't quit (an Apple Event starts an app shown). The scripts now stop if Contacts isn't running, Latchkey waits until the hidden Contacts has finished launching, and quits every Contacts it started unless it is in front |
| `battery_on_a_mac_without_one` | test + sandbox check `battery` | relay/internal/mcpserver/messages_test.go › TestStatusLine, TestOfflineText ("reason unknown, no battery"); macos/Tests/PowerSnapshotTests.swift; fixture `valid/state-no-battery.json` (FR-065a, fixed 2026-11-27) | Every answer's state line says "100% battery" on a Mac without a battery (the virtual Mac; a Mac mini, an iMac): the state message has no way to say there is none |

## Found in problem reports (2026-11-26/27, looked into 2026-11-27)

| Case | Covered by | Test | Why |
|---|---|---|---|
| `report_without_a_session` | test | relay/internal/mcpserver/fullreport_test.go › TestReportWithoutASessionCarriesTheAppsCalls | claude.ai and Claude Code use the MCP protocol without sessions, and the relay put no calls in a report without one: every report came with no calls, no pages and under a minute of log (spec 014 FR-1441) |
| `report_shows_relay_restarts` | test | relay/internal/reportlog/reportlog_test.go › TestRelayWideLinesAreInEveryAccountsLines | Calls failed while the hosted relay restarted, and the report couldn't show the restart (FR-1442a) |
| `relay_restart_keeps_running_calls` | test | relay/internal/server/shutdown_test.go › TestShutdownLetsRunningCallsFinish | A restart dropped the Macs before it stopped taking requests, so a running shell_run lost its connection (spec 001 FR-014a) |
| `browser_focus_lead` | test + Toni's conditions | macos/Tests/RegressionRealInputTests.swift › aClickComesAfterThePageHasHadTheFocusForAWhile | A sign-in page refused every real click as "too soon": the page had been focused only tens of milliseconds (spec 005 FR-483a); the real page while locked is Toni's to run |
| `own_sign_in_names_safari_way` | test | macos/Tests/OwnSessionsTests.swift › theAnswerSaysLatchkeySignsInItself | A page on a site Latchkey signs in to itself opened signed out while unlocked, and the first answer named only logins_fill, not sign_in_again into Safari (spec 013 FR-1355) |
