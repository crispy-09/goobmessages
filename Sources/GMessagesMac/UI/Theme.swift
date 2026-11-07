import SwiftUI

enum Theme {
    static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let blueGradient = LinearGradient(colors: [Color(red: 0.2, green: 0.6, blue: 1.0), Color(red: 0.0, green: 0.45, blue: 0.98)], startPoint: .top, endPoint: .bottom)
    static let receivedLight = Color(red: 0.914, green: 0.914, blue: 0.922)
    static let receivedDark = Color(red: 0.231, green: 0.231, blue: 0.239)
    static let sidebarSelection = Color(red: 0.0, green: 0.48, blue: 1.0)
}

/// iMessage-style bubble drawn as one continuous path. The body spans 5pt less than the frame on the tail
/// side; the tail flicks out into that margin. Without a tail it is a plain rounded rectangle.
struct BubbleShape: Shape {
    var fromMe: Bool
    var tail: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        if !tail {
            let body = fromMe ? CGRect(x: 0, y: 0, width: w - 5, height: h) : CGRect(x: 5, y: 0, width: w - 5, height: h)
            return Path(roundedRect: body, cornerRadius: 17, style: .continuous)
        }
        // Drawn for a received bubble (tail bottom-left); mirrored for sent.
        func x(_ v: CGFloat) -> CGFloat { fromMe ? w - v : v }
        func pt(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x(px), y: py) }
        var p = Path()
        p.move(to: pt(20, h))
        p.addLine(to: pt(w - 15, h))
        p.addCurve(to: pt(w, h - 15), control1: pt(w - 8, h), control2: pt(w, h - 8))
        p.addLine(to: pt(w, 15))
        p.addCurve(to: pt(w - 15, 0), control1: pt(w, 8), control2: pt(w - 8, 0))
        p.addLine(to: pt(20, 0))
        p.addCurve(to: pt(5, 15), control1: pt(12, 0), control2: pt(5, 8))
        p.addLine(to: pt(5, h - 10))
        p.addCurve(to: pt(0, h), control1: pt(5, h - 1), control2: pt(0, h))
        p.addLine(to: pt(-1, h))
        p.addCurve(to: pt(12, h - 4), control1: pt(4, h + 1), control2: pt(8, h - 1))
        p.addCurve(to: pt(20, h), control1: pt(15, h), control2: pt(20, h))
        p.closeSubpath()
        return p
    }
}

struct AvatarView: View {
    var image: NSImage?
    var initials: String
    var colorHex: String
    var size: CGFloat = 44
    var symbol: String? = nil
    var collage: [NSImage] = []
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if collage.count >= 2 {
                let cols = [GridItem(.fixed(size / 2), spacing: 0), GridItem(.fixed(size / 2), spacing: 0)]
                LazyVGrid(columns: cols, spacing: 0) {
                    ForEach(Array(collage.prefix(4).enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().scaledToFill().frame(width: size / 2, height: size / 2).clipped()
                    }
                }
            } else {
                Circle().fill(LinearGradient(colors: [Color(white: 0.72), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                if let symbol { Image(systemName: symbol).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white) }
                else { Text(initials).font(.system(size: size * 0.4, weight: .medium)).foregroundStyle(.white) }
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }
}

extension Date {
    var sidebarString: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return self.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        if let d = cal.dateComponents([.day], from: self, to: Date()).day, d < 7 { return self.formatted(.dateTime.weekday(.wide)) }
        return self.formatted(date: .numeric, time: .omitted)
    }
    var chatHeaderString: String {
        let cal = Calendar.current
        let time = self.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(self) { return "Today \(time)" }
        if cal.isDateInYesterday(self) { return "Yesterday \(time)" }
        return self.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " + time
    }
}
