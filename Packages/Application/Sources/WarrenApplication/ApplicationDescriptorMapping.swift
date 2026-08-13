import WarrenHost
import WarrenStateStore

/// Keeps the runtime adapter opaque to the durable state model while making
/// the conversion at the application boundary explicit and testable.
public enum RuntimeDescriptorMapping {
    public static func persisted(
        from descriptor: TerminalRuntimeDescriptor
    ) -> RuntimeAdoptionDescriptor {
        RuntimeAdoptionDescriptor(
            runtime: descriptor.runtime,
            identifier: descriptor.identifier,
            metadata: descriptor.metadata
        )
    }

    public static func runtime(
        from descriptor: RuntimeAdoptionDescriptor
    ) -> TerminalRuntimeDescriptor {
        TerminalRuntimeDescriptor(
            runtime: descriptor.runtime,
            identifier: descriptor.identifier,
            metadata: descriptor.metadata
        )
    }
}

public extension RuntimeAdoptionDescriptor {
    init(_ descriptor: TerminalRuntimeDescriptor) {
        self = RuntimeDescriptorMapping.persisted(from: descriptor)
    }
}

public extension TerminalRuntimeDescriptor {
    init(_ descriptor: RuntimeAdoptionDescriptor) {
        self = RuntimeDescriptorMapping.runtime(from: descriptor)
    }
}
