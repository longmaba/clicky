import Foundation

public struct KeyDescriptor: Identifiable, Equatable {
    public var usage: UInt32
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var id: String { "7:\(usage)" }
    public init(_ usage: UInt32, _ label: String, _ x: Double, _ y: Double, _ width: Double = 1) {
        self.usage = usage; self.label = label; self.x = x; self.y = y; self.width = width
    }
}

public enum KeyboardLayout {
    public static let totalWidth: Double = 15
    public static let rows = 6
    public static let keys: [KeyDescriptor] = {
        var k: [KeyDescriptor] = [KeyDescriptor(41, "esc", 0, 0, 1.5)]
        for i in 0..<12 { k.append(KeyDescriptor(UInt32(58 + i), "F\(i+1)", 1.5 + Double(i), 0)) }
        k.append(KeyDescriptor(76, "⌦", 13.5, 0, 1.5))
        let numbers: [(UInt32, String)] = [(53,"`"),(30,"1"),(31,"2"),(32,"3"),(33,"4"),(34,"5"),(35,"6"),(36,"7"),(37,"8"),(38,"9"),(39,"0"),(45,"−"),(46,"=")]
        for (i, p) in numbers.enumerated() { k.append(KeyDescriptor(p.0, p.1, Double(i), 1)) }
        k.append(KeyDescriptor(42,"⌫",13,1,2))
        k.append(KeyDescriptor(43,"tab",0,2,1.5))
        let top: [(UInt32,String)] = [(20,"Q"),(26,"W"),(8,"E"),(21,"R"),(23,"T"),(28,"Y"),(24,"U"),(12,"I"),(18,"O"),(19,"P"),(47,"["),(48,"]")]
        for (i,p) in top.enumerated() { k.append(KeyDescriptor(p.0,p.1,1.5+Double(i),2)) }
        k.append(KeyDescriptor(49,"\\",13.5,2,1.5))
        k.append(KeyDescriptor(57,"caps",0,3,1.75))
        let home: [(UInt32,String)] = [(4,"A"),(22,"S"),(7,"D"),(9,"F"),(10,"G"),(11,"H"),(13,"J"),(14,"K"),(15,"L"),(51,";"),(52,"'")]
        for (i,p) in home.enumerated() { k.append(KeyDescriptor(p.0,p.1,1.75+Double(i),3)) }
        k.append(KeyDescriptor(40,"return",12.75,3,2.25))
        k.append(KeyDescriptor(225,"shift",0,4,2.25))
        let bottom: [(UInt32,String)] = [(29,"Z"),(27,"X"),(6,"C"),(25,"V"),(5,"B"),(17,"N"),(16,"M"),(54,","),(55,"."),(56,"/")]
        for (i,p) in bottom.enumerated() { k.append(KeyDescriptor(p.0,p.1,2.25+Double(i),4)) }
        k.append(KeyDescriptor(229,"shift",12.25,4,2.75))
        k += [KeyDescriptor(255,"fn",0,5),KeyDescriptor(224,"⌃",1,5),KeyDescriptor(226,"⌥",2,5),KeyDescriptor(227,"⌘",3,5,1.25),KeyDescriptor(44,"space",4.25,5,5),KeyDescriptor(231,"⌘",9.25,5,1.25),KeyDescriptor(230,"⌥",10.5,5),KeyDescriptor(80,"←",11.5,5),KeyDescriptor(81,"↓",12.5,5),KeyDescriptor(82,"↑",13.5,5,0.75),KeyDescriptor(79,"→",14.25,5,0.75)]
        return k
    }()
    private static let byUsage = Dictionary(uniqueKeysWithValues: keys.map { ($0.usage, $0) })
    public static func label(for usage: UInt32, page: UInt32 = 7) -> String {
        if page == 9 { return [1:"LMB",2:"RMB",3:"MMB"][usage] ?? "Mouse \(usage)" }
        if page == 12 { return [0xE9:"Vol+",0xEA:"Vol−",0xE2:"Mute",0xCD:"⏯",0xB5:"⏭",0xB6:"⏮",0x6F:"☀+",0x70:"☀−"][usage] ?? "Media" }
        return byUsage[usage]?.label ?? [50:"#",100:"\\",88:"enter",101:"menu",74:"home",77:"end",75:"pgup",78:"pgdn"][usage] ?? "Key \(usage)"
    }
    public static func pan(for usage: UInt32, page: UInt32 = 7) -> Float {
        guard page == 7, let key = byUsage[usage] else { return 0 }
        return Float((key.x + key.width / 2) / totalWidth * 2 - 1)
    }
    public static func isHomeRow(_ usage: UInt32) -> Bool { [4,22,7,9,13,14,15,51].contains(usage) }
    public static func modifier(for usage: UInt32) -> KeyModifiers {
        switch usage { case 224,228: return .control; case 225,229: return .shift; case 226,230: return .option; case 227,231: return .command; case 255: return .function; default: return [] }
    }
}
