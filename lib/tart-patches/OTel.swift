import OpenTelemetryApi

// Preserve upstream tracing call sites without collecting or exporting data.
// This build contains no tracing SDK, resource collector or exporter.
final class OTel {
    static let shared = OTel()
    let tracer: Tracer = DefaultTracer.instance
    func flush() {}
}
