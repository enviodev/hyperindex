//! Where an entry begins in the text it was read from, as a line and column,
//! so a message about the entry can point into the file.

pub(crate) fn line_and_column(text: &str, offset: usize) -> (usize, usize) {
    let before = &text[..offset];
    let line = before.matches('\n').count() + 1;
    let start_of_line = before.rfind('\n').map_or(0, |newline| newline + 1);
    // Columns count characters, the way an editor does, not bytes.
    let column = before[start_of_line..].chars().count() + 1;
    (line, column)
}

/// Where each entry begins, given the entries' own text. They are searched for
/// in order, so two written identically resolve to their own positions instead
/// of both to the first.
pub(crate) fn locate<'a>(
    text: &str,
    entries: impl IntoIterator<Item = &'a str>,
) -> Vec<(usize, usize)> {
    let mut cursor = 0;
    entries
        .into_iter()
        .map(|entry| {
            let offset = text[cursor..]
                .find(entry)
                .map_or(cursor, |index| cursor + index);
            cursor = offset + entry.len();
            line_and_column(text, offset)
        })
        .collect()
}
