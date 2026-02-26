import XCTest
@testable import MoleMenuBarCore

final class FormatRateTests: XCTestCase {
    func testZeroRate() {
        XCTAssertEqual(formatRate(0), "0 MB/s")
        XCTAssertEqual(formatRate(0.005), "0 MB/s")
    }

    func testSubMBRate() {
        XCTAssertEqual(formatRate(0.01), "0.01 MB/s")
        XCTAssertEqual(formatRate(0.5), "0.50 MB/s")
        XCTAssertEqual(formatRate(0.99), "0.99 MB/s")
    }

    func testLowMBRate() {
        XCTAssertEqual(formatRate(1.0), "1.0 MB/s")
        XCTAssertEqual(formatRate(5.5), "5.5 MB/s")
        XCTAssertEqual(formatRate(9.9), "9.9 MB/s")
    }

    func testHighMBRate() {
        XCTAssertEqual(formatRate(10.0), "10 MB/s")
        XCTAssertEqual(formatRate(100.5), "100 MB/s")
        XCTAssertEqual(formatRate(1024.0), "1024 MB/s")
    }
}

final class HumanBytesTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(humanBytes(0), "0 B")
        XCTAssertEqual(humanBytes(512), "512 B")
    }

    func testMegabytes() {
        let mb = UInt64(1) << 20
        XCTAssertEqual(humanBytes(mb), "1.0 MB")
        XCTAssertEqual(humanBytes(mb * 500), "500.0 MB")
    }

    func testGigabytes() {
        let gb = UInt64(1) << 30
        XCTAssertEqual(humanBytes(gb), "1.0 GB")
        XCTAssertEqual(humanBytes(gb * 24), "24.0 GB")
    }

    func testTerabytes() {
        let tb = UInt64(1) << 40
        XCTAssertEqual(humanBytes(tb), "1.0 TB")
        XCTAssertEqual(humanBytes(tb * 2), "2.0 TB")
    }
}

final class HumanBytesShortTests: XCTestCase {
    func testSmallValues() {
        XCTAssertEqual(humanBytesShort(0), "0")
        XCTAssertEqual(humanBytesShort(1024), "1024")
    }

    func testMegabytes() {
        let mb = UInt64(1) << 20
        XCTAssertEqual(humanBytesShort(mb * 100), "100M")
    }

    func testGigabytes() {
        let gb = UInt64(1) << 30
        XCTAssertEqual(humanBytesShort(gb * 500), "500G")
    }
}

final class MetricsSnapshotDecodingTests: XCTestCase {
    func testDecodeMinimalJSON() throws {
        let json = """
        {"HealthScore":95,"HealthScoreMsg":"Excellent"}
        """
        let snap = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.HealthScore, 95)
        XCTAssertEqual(snap.HealthScoreMsg, "Excellent")
        XCTAssertNil(snap.CPU)
    }

    func testDecodeCPUAndMemory() throws {
        let json = """
        {"CPU":{"Usage":15.5,"Load1":2.1,"Load5":1.8,"Load15":1.5},"Memory":{"Used":15032385536,"Total":25769803776,"UsedPercent":58.3}}
        """
        let snap = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.CPU?.Usage, 15.5)
        XCTAssertEqual(snap.CPU?.Load1, 2.1)
        XCTAssertEqual(snap.Memory?.UsedPercent, 58.3)
        XCTAssertEqual(snap.Memory?.Total, 25769803776)
    }

    func testDecodeEmptyJSON() throws {
        let json = "{}"
        let snap = try JSONDecoder().decode(MetricsSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.HealthScore)
        XCTAssertNil(snap.CPU)
        XCTAssertNil(snap.Memory)
    }
}
