# maildir

Nim library and CLI for the [Maildir](https://cr.yp.to/proto/maildir.html) format. Delivers, reads, flags, and deletes messages with proper atomic semantics. Handles MIME attachments too.

## Installation

Requires [Nim](https://nim-lang.org/).

    nimble install maildir

## Library usage

```nim
import maildir

# Create a new maildir (or open an existing one)
let md = init("/tmp/mail")

# Deliver a message
let msg = md.deliver("From: me@example.com\nTo: you@example.com\nSubject: Hello\n\nHow's it going?")
echo msg.uniqueName  # something like 1712345678.M123P456Q1.hostname

# List and read
for m in md.list():
  echo m.dir, "/", m.uniqueName
  echo m.read()

# Find by name (or prefix)
let found = md.get("1712345678")
```

Default headers (Date, MIME-Version, Content-Type, Content-Transfer-Encoding, Message-ID) are added automatically if missing. From and To are required -- deliver will raise if they're absent.

### Flags

Standard maildir flags: Seen, Flagged, Replied, Trashed, Draft, Passed.

```nim
let seen = md.markSeen(msg)       # moves to cur/, adds S flag
let flagged = md.markFlagged(msg) # adds F flag
let trashed = md.trash(msg)       # adds T flag

# Or set flags directly
let updated = md.setFlags(msg, {fSeen, fFlagged, fReplied})

# Bulk cleanup
md.purge()  # deletes all messages flagged as trashed
```

### Attachments

```nim
import maildir

let md = init("/tmp/mail")

# Deliver with attachments
let att = Attachment(
  filename: "report.pdf",
  contentType: "application/pdf",
  data: readFile("report.pdf")
)
let msg = md.deliver(
  "From: me@x.com\nTo: you@x.com\nSubject: Report\n\nSee attached.",
  @[att]
)

# List attachments on a message
let content = msg.read()
for a in listAttachments(content):
  echo a.filename, " (", a.contentType, ")"

# Extract by index or filename
let extracted = extractAttachment(content, 0)
writeFile(extracted.filename, extracted.data)
```

Attachments are base64-encoded into a multipart/mixed message. The original body content type is preserved as the first MIME part.

## CLI

The binary gives you the same operations from the shell.

```bash
# Create a maildir
maildir init /tmp/mail

# Deliver (reads from stdin)
echo "From: me@x.com\nTo: you@x.com\nSubject: Hi\n\nHello" | maildir deliver /tmp/mail

# Deliver with attachments
maildir deliver /tmp/mail --message "From: me@x.com\nTo: you@x.com\n\nSee attached" \
  --attach report.pdf --attach data.csv

# List messages
maildir list /tmp/mail
maildir list /tmp/mail --new-only
maildir list /tmp/mail --count

# Read a message
maildir read /tmp/mail <unique-name>

# Flags
maildir flag /tmp/mail <unique-name> --seen --flagged

# Attachments
maildir attachments /tmp/mail <unique-name>
maildir extract /tmp/mail <unique-name> --index 0
maildir extract /tmp/mail <unique-name> --filename report.pdf --output /tmp/report.pdf

# Cleanup
maildir delete /tmp/mail <unique-name>
maildir purge /tmp/mail    # remove all trashed
maildir clean /tmp/mail    # remove stale tmp/ files (>36h)

# Version
maildir version
```

## How it works

Follows the [Maildir spec](https://cr.yp.to/proto/maildir.html):

- Three directories: `tmp/`, `new/`, `cur/`
- Unique filenames from timestamp + pid + hostname + counter
- Atomic delivery: write to `tmp/`, rename to `new/`
- Flags encoded in filename suffix (`:2,` followed by flag characters)
- `cleanTmp` removes files in `tmp/` older than 36 hours per spec

## License

MIT
