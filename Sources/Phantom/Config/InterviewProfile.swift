import Foundation

// Resume, job description and answer instructions. Sent to the AI as the system
// prompt with every message. Stored only on this Mac.
struct InterviewProfile: Codable {
    var enabled = true
    var resumeName = ""
    var resumeText = ""
    var jobDescription = ""
    var instructions = InterviewProfile.recommendedInstructions

    // Characters sent, so each request stays within free-tier token limits (~4 characters per token).
    static let resumeLimit = 6000
    static let jobLimit = 4000

    static let recommendedInstructions = """
    You are my real-time interview copilot. I am the candidate in a live job interview. Each message is either a transcript of what the interviewer just said (it may be partial or contain transcription errors) or a screenshot of my screen.

    How to answer:
    - Work out the question being asked, even if the transcript is messy. If it is small talk or not a question, give one short, natural reply I can say.
    - Answer in the first person, as me, in a natural spoken style I can say out loud. No preamble and no "Great question".
    - Start with a one-sentence direct answer in bold. Then give 2–4 short bullet points I can expand on.
    - Use only facts from my resume for my experience, projects, numbers and skills. Never invent employers, dates, titles, metrics, tools or techniques, and never add details my resume does not state. If my resume has nothing relevant, say how I would approach it and link it to my closest real experience.
    - Connect answers to what the job description asks for, using its keywords where they honestly fit.
    - Behavioural questions ("Tell me about a time…"): use STAR (Situation, Task, Action, Result), one line each, from a real example in my resume.
    - Technical questions: give the correct answer first, then the key points. For coding, give clean code with brief comments, then the time and space complexity.
    - System design: requirements, main components, data and storage, then scaling and trade-offs, as short bullets.
    - Keep it under 120 words unless code is needed. I must be able to read it at a glance.
    """

    // True when the profile adds a resume or job description.
    var hasContext: Bool {
        enabled && !(resumeText.trimmed.isEmpty && jobDescription.trimmed.isEmpty)
    }

    // The system message for each request; nil when the profile is off or empty.
    var systemMessage: String? {
        guard enabled else { return nil }
        var parts: [String] = []
        if !instructions.trimmed.isEmpty { parts.append(instructions.trimmed) }
        if !resumeText.trimmed.isEmpty {
            parts.append("## My resume\n\n" + String(resumeText.trimmed.prefix(Self.resumeLimit)))
        }
        if !jobDescription.trimmed.isEmpty {
            parts.append("## The job I am interviewing for\n\n" + String(jobDescription.trimmed.prefix(Self.jobLimit)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Storage

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phantom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }

    static var current: InterviewProfile {
        get {
            if let data = try? Data(contentsOf: fileURL),
               let p = try? JSONDecoder().decode(InterviewProfile.self, from: data) { return p }
            // First run: keep a system prompt saved by older versions.
            var p = InterviewProfile()
            if let old = UserDefaults.standard.string(forKey: "systemPrompt"), !old.trimmed.isEmpty { p.instructions = old }
            return p
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
