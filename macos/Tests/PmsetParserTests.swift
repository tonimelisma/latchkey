import Testing

@testable import Latchkey

@Suite struct PmsetParserTests {
    static let sample = """
        System-wide power settings:
         SleepDisabled\t\t1
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         networkoversleep     0
         disksleep            10
         sleep                1 (sleep prevented by powerd)
         hibernatemode        3
         ttyskeepawake        1
         displaysleep         10
         tcpkeepalive         1
         lowpowermode         0
         womp                 0
        """

    @Test func readsSleepDisabled() {
        #expect(PmsetParser.sleepDisabled(Self.sample) == true)
        #expect(
            PmsetParser.sleepDisabled(
                Self.sample.replacingOccurrences(of: "SleepDisabled\t\t1", with: "SleepDisabled\t\t0")) == false)
    }

    @Test func missingMeansOff() {
        // pmset omits the line when the setting was never changed.
        #expect(PmsetParser.sleepDisabled("System-wide power settings:\nCurrently in use:\n sleep 1\n") == false)
    }

    @Test func doesNotConfuseOtherLines() {
        #expect(PmsetParser.sleepDisabled(" disablesleepish 1\n sleep 1\n") == false)
    }
}
