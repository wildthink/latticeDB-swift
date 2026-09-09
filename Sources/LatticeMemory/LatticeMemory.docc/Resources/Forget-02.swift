let request = ForgetRequest(identifiers: [ingested.evidence.id], mode: .tombstone)

let preview = try store.forgetPreview(request)
print(preview.evidence.count, preview.retractedAssertions.count)
// 1 1

let report = try store.forget(request)
print(report.wasApplied)
// true
