public enum TerminationDecision: Equatable, Sendable { case terminateNow, requestConfirmation }
public enum TerminationPolicy {
    public static func decision(queueActive: Bool) -> TerminationDecision {
        queueActive ? .requestConfirmation : .terminateNow
    }
}
