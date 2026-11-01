// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/normalizeContainers.swift
extension Workspace {
    @MainActor func normalizeContainers() throws {
        try rootTilingContainer.unbindEmptyAndAutoFlatten() // Beware! rootTilingContainer may change after this line of code
        if config.enableNormalizationOppositeOrientationForNestedContainers {
            try rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten() throws {
        // Pilot (scrolling layout, Stage layout): a strip's or a stage's root stays itself with one stack left in it, or the
        // workspace would stop scrolling or lose its shelf's room
        if let child = children.singleOrNil(), config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer)
            && !(isRootContainer && layout.isRow)
        {
            try child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = try unbindFromParent()
            try child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            try (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                try (child as? TilingContainer)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                try unbindFromParent()
            }
        }
    }
}
