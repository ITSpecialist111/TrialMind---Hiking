import XCTest
@testable import TrailMind

/// The shell's layout rules: Android's narrow/wide split, iPhone Duo's vertical bars, cameras and fold poses.
final class ShellGeometryTests: XCTestCase {
    private typealias G = ShellGeometry

    private func resolve(_ w: CGFloat, _ h: CGFloat, safe: G.Insets = G.Insets(), fold: CGRect? = nil, edge: G.BarEdge? = nil,
                         occlusions: [CGRect] = [], fullScreen: Bool = false) -> G {
        G.resolve(size: CGSize(width: w, height: h), safe: safe, fold: fold, verticalBarEdge: edge,
                  occlusions: occlusions, fullScreen: fullScreen, compactTabCount: 5)
    }

    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 0.001, "x of \(r)", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 0.001, "y of \(r)", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.001, "width of \(r)", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 0.001, "height of \(r)", file: file, line: line)
    }

    /// No overlapping area (rects may share an edge; Linux Foundation's `intersects` counts touching edges).
    private func assertClear(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let i = a.intersection(b)
        XCTAssertTrue(i.isNull || i.width * i.height == 0, "\(a) overlaps \(b)", file: file, line: line)
    }

    func testPhonePortraitUsesBottomCapsule() {
        let g = resolve(390, 844, safe: G.Insets(top: 47, bottom: 34))
        XCTAssertEqual(g.mode, .compact)
        XCTAssertEqual(g.nav, .bottom)
        XCTAssertTrue(g.compactTabs)
        XCTAssertTrue(g.usesCapsule)
        XCTAssertFalse(g.usesRail)
        assertRect(g.capsuleFrame, 8, 740, 374, 60)
        assertRect(g.mapArea, 0, 47, 390, 683)
        XCTAssertEqual(g.pageInsets, G.Insets(bottom: 74))
    }

    func testPhoneLandscapeUsesRailWithFiveTabs() {
        let g = resolve(844, 390, safe: G.Insets(leading: 47, bottom: 21, trailing: 47))
        XCTAssertEqual(g.mode, .wide)
        XCTAssertTrue(g.compactTabs, "short windows only fit five destinations")
        XCTAssertTrue(g.menuOnLeading)
        assertRect(g.railFrame, 47, 0, 76, 390)
        assertRect(g.paneFrame, 123, 8, 260, 353)
        assertRect(g.mapArea, 391, 0, 406, 369)
        XCTAssertEqual(g.pageInsets, G.Insets())
    }

    func testPaneWidthIs29PercentClamped() {
        XCTAssertEqual(resolve(832, 900).paneFrame.width, 260, accuracy: 0.001)
        XCTAssertEqual(resolve(1000, 900).paneFrame.width, 290, accuracy: 0.001)
        XCTAssertEqual(resolve(1200, 900).paneFrame.width, 340, accuracy: 0.001)
    }

    func testWidthThresholdMatchesAndroid() {
        XCTAssertEqual(resolve(599, 900).mode, .compact)
        XCTAssertEqual(resolve(600, 900).mode, .wide)
    }

    func testDuoOuterDisplayStandsCapsuleOnBarEdgeClearOfCamera() {
        let camera = CGRect(x: 50, y: 250, width: 40, height: 40)
        let g = resolve(360, 780, safe: G.Insets(top: 20, leading: 40, bottom: 20), edge: .leading, occlusions: [camera])
        XCTAssertEqual(g.mode, .compact)
        XCTAssertEqual(g.nav, .leading)
        assertRect(g.capsuleFrame, 46, 298, 60, 252)
        assertClear(g.capsuleFrame, camera)
        assertRect(g.mapArea, 116, 20, 244, 740)
        XCTAssertEqual(g.pageInsets, G.Insets(leading: 70))
    }

    func testDuoOuterDisplayTrailingBars() {
        let g = resolve(360, 780, safe: G.Insets(top: 20, bottom: 20, trailing: 40), edge: .trailing)
        XCTAssertEqual(g.nav, .trailing)
        XCTAssertFalse(g.menuOnLeading)
        assertRect(g.capsuleFrame, 254, 264, 60, 252)
        assertRect(g.mapArea, 0, 20, 244, 740)
        XCTAssertEqual(g.pageInsets, G.Insets(trailing: 70))
    }

    func testCameraBelowCentreMovesCapsuleUp() {
        let camera = CGRect(x: 50, y: 500, width: 40, height: 40)
        let g = resolve(360, 780, safe: G.Insets(top: 20, leading: 40, bottom: 20), edge: .leading, occlusions: [camera])
        assertClear(g.capsuleFrame, camera)
        XCTAssertEqual(g.capsuleFrame.maxY, 492, accuracy: 0.001)
    }

    func testDuoInnerDisplayFlatUsesWideLayout() {
        let g = resolve(832, 900, safe: G.Insets(top: 30, bottom: 20))
        XCTAssertEqual(g.mode, .wide)
        XCTAssertFalse(g.compactTabs)
        assertRect(g.railFrame, 0, 0, 76, 900)
        assertRect(g.paneFrame, 76, 38, 260, 834)
        assertRect(g.mapArea, 344, 30, 488, 850)
    }

    func testBookPosePutsMenuAndMapEitherSideOfFold() {
        let fold = CGRect(x: 411, y: 0, width: 10, height: 900)
        let g = resolve(832, 900, safe: G.Insets(top: 30, bottom: 20), fold: fold)
        XCTAssertEqual(g.mode, .foldBook)
        XCTAssertTrue(g.usesRail)
        XCTAssertFalse(g.compactTabs)
        assertRect(g.railFrame, 0, 0, 76, 900)
        assertRect(g.paneFrame, 76, 38, 327, 834)
        assertRect(g.mapArea, 421, 30, 411, 850)
        assertClear(g.paneFrame, fold)
        assertClear(g.mapArea, fold)
    }

    func testBookPoseFollowsTrailingBars() {
        let fold = CGRect(x: 411, y: 0, width: 10, height: 900)
        let g = resolve(832, 900, safe: G.Insets(top: 30, bottom: 20), fold: fold, edge: .trailing)
        XCTAssertEqual(g.mode, .foldBook)
        XCTAssertFalse(g.menuOnLeading)
        assertRect(g.railFrame, 756, 0, 76, 900)
        assertRect(g.paneFrame, 429, 38, 327, 834)
        assertRect(g.mapArea, 0, 30, 411, 850)
    }

    func testTabletopPoseStandsMapAboveFold() {
        let fold = CGRect(x: 0, y: 411, width: 900, height: 10)
        let g = resolve(900, 832, safe: G.Insets(top: 24, bottom: 20), fold: fold)
        XCTAssertEqual(g.mode, .foldTable)
        XCTAssertEqual(g.nav, .bottom)
        XCTAssertTrue(g.compactTabs)
        XCTAssertTrue(g.usesCapsule)
        assertRect(g.capsuleFrame, 270, 742, 360, 60)
        assertRect(g.paneFrame, 0, 425, 900, 313)
        assertRect(g.mapArea, 0, 24, 900, 387)
        assertClear(g.mapArea, fold)
        assertClear(g.paneFrame, fold)
    }

    func testFullScreenMapUsesWholeSafeArea() {
        let wide = resolve(844, 390, safe: G.Insets(leading: 47, bottom: 21, trailing: 47), fullScreen: true)
        XCTAssertTrue(wide.fullScreen)
        assertRect(wide.mapArea, 47, 0, 750, 369)
        let book = resolve(832, 900, safe: G.Insets(top: 30, bottom: 20), fold: CGRect(x: 411, y: 0, width: 10, height: 900), fullScreen: true)
        XCTAssertTrue(book.fullScreen)
        assertRect(book.mapArea, 0, 30, 832, 850)
        XCTAssertFalse(resolve(390, 844, fullScreen: true).fullScreen, "the narrow layout has no full-screen mode")
    }

    func testEmptyFoldIsIgnored() {
        XCTAssertEqual(resolve(390, 844, fold: .zero).mode, .compact)
        XCTAssertNil(resolve(390, 844, fold: .zero).fold)
        XCTAssertEqual(resolve(832, 900, fold: .zero).mode, .wide)
    }
}
