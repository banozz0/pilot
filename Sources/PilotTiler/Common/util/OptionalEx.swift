// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/util/OptionalEx.swift
extension Optional {
    public func orFault(
        _ message: String = "",
        file: StaticString = #fileID,
        line: Int = #line,
        column: Int = #column,
        function: String = #function,
    ) throws(TilerFault) -> Wrapped {
        if let self { return self }
        try raiseFault("orFault: " + message, file: file, line: line, column: column, function: function)
    }

    public func asList() -> [Wrapped] {
        switch self {
            case let ok?: [ok]
            case nil: []
        }
    }

    public var prettyDescription: String {
        switch self {
            case let ok?: String(describing: ok)
            case nil: "nil"
        }
    }
}
