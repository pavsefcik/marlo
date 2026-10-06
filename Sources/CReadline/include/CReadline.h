#ifndef MARLO_C_READLINE_H
#define MARLO_C_READLINE_H

/// Returns the completion at `index` for `word`, or NULL when exhausted.
///
/// `index` starts at 0 and increases until NULL is returned.
///
/// `line` is the whole line being edited, not just the word under the cursor.
/// libedit only hands its callback the word, which is not enough to decide what
/// to complete: `o` means something different after `/tools` than after
/// `/resume`. The line is passed alongside so the callback can see both.
typedef const char *(*marlo_completion_fn)(const char *line, const char *word, int index);

/// Install a completion source and enable history.
///
/// Must be called before the first `marlo_readline` call. Passing NULL leaves
/// completion disabled but history working.
void marlo_readline_setup(marlo_completion_fn fn);

/// Read one line with editing, history and completion. Returns a malloc'd
/// string the caller must free, or NULL at end of input.
char *marlo_readline(const char *prompt);

/// Append a line to the in-memory history.
void marlo_readline_add_history(const char *line);

/// Read one line without editing, for when stdin is not a terminal.
///
/// Returns a malloc'd string the caller must free, or NULL at end of input.
char *marlo_readline_plain(void);

#endif
