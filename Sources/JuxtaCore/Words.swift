import Foundation

/// What a double-click selects. Words are shaped for configs and show output: a run of
/// letters, digits and `. : / - _` is one word, so `10.1.1.1/24`, `2001:db8::1`,
/// `GigabitEthernet0/0/1` and `route-map` each select whole. Any other character,
/// including a space, is a word of its own, as in Terminal.
public enum Words {
    /// The UTF-16 range of the word containing the character at `offset` in `line`.
    /// An offset at the end of the line picks the last character, as a click past the
    /// end does; an empty line gives an empty range. Characters (grapheme clusters) are
    /// never split, so a surrogate pair or a combining sequence stays whole.
    public static func range(at offset: Int, in line: String) -> Range<Int> {
        // A click past the end picks the last character.
        let offset = min(offset, line.utf16.count - 1)
        var runStart = 0, position = 0
        var found = false
        for character in line {
            let width = character.utf16.count
            let inWord = isWordCharacter(character)
            if found {
                // Past the clicked character: its word ends at the first other character.
                guard inWord else { break }
            } else if offset < position + width {
                guard inWord else { return position..<position + width }
                found = true
            } else if !inWord {
                runStart = position + width
            }
            position += width
        }
        return found ? runStart..<position : position..<position
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ".:/-_".contains(character)
    }
}
