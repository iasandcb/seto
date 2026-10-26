import Testing
@testable import Sebeol390Core

@Test func languageBoundariesPreserveHangulUnits() {
    for (keys, boundary) in [
        ("kf", 1),       // ㄱ | ㅏ
        ("kkf", 1),      // ㄱ | ㄱㅏ (ㄲ)
        ("kvf", 2),      // 고 | ㅏ (과)
        ("kfx", 2),      // 가 | ㄱ (각)
        ("kfxq", 3),     // 각 | ㅅ (갃)
        ("kvif3", 4),    // 고마 | ㅂ (고맙)
    ] {
        let atoms = keys.map { Layout390.atom(for: $0) }
        #expect(!Composer.preservesBoundary(boundary, in: atoms), "\(keys) at \(boundary)")
    }
    for (keys, boundary) in [
        ("kfhf", 2),     // 가 | 나
        ("kvif3", 2),    // 고 | 맙
        ("ktx hgs", 3), // 걱 | space
        ("deploymr2", 6), // deploy | 했
        ("apiyhw", 3),  // api | 를
    ] {
        let atoms = keys.map { Layout390.atom(for: $0) }
        #expect(Composer.preservesBoundary(boundary, in: atoms), "\(keys) at \(boundary)")
    }
}

@Test func commonWordsCompose() {
    expect("mfskgw", "한글")
    expect("jfsheamfncj4", "안녕하세요")
    expect("nc;twndx", "세벌식")
    expect("mr2ng3hduf", "했습니다")
    expect("lv1jfj4", "좋아요")
    expect("jd2uf", "있다")
    expect("mr2hgsuc", "했는데")
    expect("mrnt", "해서")
}

@Test func compoundsCompose() {
    expect("kvf", "과")
    expect("j8", "의")
    expect("jgd", "의")
    expect("kkf", "까")
    expect("kf3q", "값")
    expect("kfX", "값")
    expect("kfxq", "갃")
    expect("kfF", "갂")
    expect("hfwq", "낤")
    expect("hfW", "낱")
}

@Test func vowelOrderIsNotReversed() {
    let text = compose("fk")
    #expect(text != "과")
    #expect(text.contains("ㅏ"))
}

@Test func symbolBreaksSyllable() {
    #expect(compose("kf.") == "가.")
}

@Test func shorterPrefixDropsLastJamo() {
    #expect(compose(String("kkf".dropLast())) == "ㄲ")
    #expect(compose(String("kf".dropLast())) == "ㄱ")
}

private func expect(_ keys: String, _ word: String) {
    #expect(compose(keys) == word, "\(keys)")
}

private func compose(_ keys: String) -> String {
    Composer.compose(keys.map { Layout390.atom(for: $0) }).text
}
