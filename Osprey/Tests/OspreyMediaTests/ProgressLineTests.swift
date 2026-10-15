import Testing
@testable import OspreyMedia

@Suite struct ProgressLineTests {
    @Test func parsesAFullLine() throws {
        let p = try #require(ProgressLine.parse("SLIPPROG 1048576 5242880 NA 262144.5 17 3 10"))
        #expect(p.downloaded == 1_048_576)
        #expect(p.total == 5_242_880)
        #expect(p.speed == 262_144.5)
        #expect(p.fragment?.0 == 3 && p.fragment?.1 == 10)
    }

    @Test func fallsBackToTheEstimateWhenTotalIsNA() throws {
        let p = try #require(ProgressLine.parse("SLIPPROG 500 NA 9000.7 NA NA NA NA"))
        #expect(p.total == 9000)
        #expect(p.speed == nil)
        #expect(p.fragment == nil)
    }

    @Test func noTotalAtAll() throws {
        let p = try #require(ProgressLine.parse("SLIPPROG 0 NA NA NA NA 1 4"))
        #expect(p.total == nil)
        #expect(p.fragment?.0 == 1 && p.fragment?.1 == 4)
    }

    @Test(arguments: ["", "garbage", "SLIPPROG", "SLIPPROG NA NA NA NA NA NA NA", "SLIPPROG 1 2 3",
                      "[download] 10% of 5MiB", "PROG 1 2 3 4 5 6 7", "SLIPPROG x 1 2 3 4 5 6"])
    func malformedLinesReturnNil(_ line: String) {
        #expect(ProgressLine.parse(line) == nil)
    }
}
