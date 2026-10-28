// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/AxUiElementMock.swift
import AppKit

/// Alternative name: AttrAddressibleStorage
protocol AxUiElementMock {
    func get<Attr: ReadableAttr>(_ attr: Attr) -> Attr.T?
    func containingWindowId() -> CGWindowID?
}

extension AxUiElementMock {
    var cast: AXUIElement {
        get throws(TilerFault) {
            let object = self as AnyObject
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { try raiseFault("\(self) is not an AXUIElement") }
            return object as! AXUIElement
        }
    }
}
