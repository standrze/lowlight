/// Applies chat presentation defaults at the instruction boundary while keeping
/// user instructions and active skill snapshots unchanged.
public enum ChatSystemPrompt {
    public static let codePresentationDefaults = """
        Code presentation defaults (unless the user's instructions or task require otherwise): Write plain code and comments. Do not add emoji, emoticons, keycap badges, decorative Unicode arrows, numbered section comments, or Markdown formatting inside code. Keep comments short and useful. Put code in fenced blocks so it is rendered literally. Preserve required syntax, operators, numeric values, string contents, and meaning; include Unicode when explicitly requested or needed for the program or data.
        """

    public static func compose(base: String?, skills: [SkillDocument]) -> String {
        guard let instructions = composeSystemPrompt(base: base, skills: skills), !instructions.isEmpty else {
            return codePresentationDefaults
        }
        return codePresentationDefaults + "\n\n" + instructions
    }
}
