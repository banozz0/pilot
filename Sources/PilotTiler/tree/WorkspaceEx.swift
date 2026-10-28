// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/tree/WorkspaceEx.swift

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        get throws {
            let containers = children.filterIsInstance(of: TilingContainer.self)
            switch containers.count {
                case 0:
                    let orientation: Orientation = switch config.defaultRootContainerOrientation {
                        case .horizontal: .h
                        case .vertical: .v
                        case .auto: workspaceMonitor.then { $0.width >= $0.height } ? .h : .v
                    }
                    return try TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout, index: INDEX_BIND_LAST)
                case 1:
                    return try containers.singleOrNil().orFault()
                default:
                    try raiseFault("Workspace must contain zero or one tiling container as its child")
            }
        }
    }

    @MainActor
    var floatingWindows: [Window] {
        get throws {
            try floatingWindowsContainer.children.filterIsInstance(of: Window.self)
        }
    }

    @MainActor
    var floatingWindowsContainer: FloatingWindowsContainer {
        get throws {
            let containers = children.filterIsInstance(of: FloatingWindowsContainer.self)
            return switch containers.count {
                case 0: try FloatingWindowsContainer(parent: self)
                case 1: try containers.singleOrNil().orFault()
                default: try raiseFaultT("Workspace must contain zero or one FloatingWindowsContainer")
            }
        }
    }

    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        get throws {
            let containers = children.filterIsInstance(of: MacosFullscreenWindowsContainer.self)
            return switch containers.count {
                case 0: try MacosFullscreenWindowsContainer(parent: self)
                case 1: try containers.singleOrNil().orFault()
                default: try raiseFaultT("Workspace must contain zero or one MacosFullscreenWindowsContainer")
            }
        }
    }

    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        get throws {
            let containers = children.filterIsInstance(of: MacosHiddenAppsWindowsContainer.self)
            return switch containers.count {
                case 0: try MacosHiddenAppsWindowsContainer(parent: self)
                case 1: try containers.singleOrNil().orFault()
                default: try raiseFaultT("Workspace must contain zero or one MacosHiddenAppsWindowsContainer")
            }
        }
    }

    @MainActor var forceAssignedMonitor: MonitorInfo? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = sortedMonitorInfos
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitor(sortedMonitors: sortedMonitors) }
            .first
    }
}
