## maildir/core - Maildir format operations
##
## Implements the Maildir specification (https://cr.yp.to/proto/mailstruc.html):
## - Three subdirectories: tmp, new, cur
## - Unique filenames using timestamp, pid, hostname, and a counter
## - Atomic delivery via tmp -> new rename
## - Flags encoded in filename suffix after `:2,`

import std/[os, times, strutils, algorithm, posix, tables]

type
  Flag* = enum
    ## Standard maildir flags (STRSTRINGS in :2, suffix)
    fPassed   ## P - forwarded/bounced/resent
    fReplied  ## R - replied to
    fSeen     ## S - read
    fTrashed  ## T - marked for deletion
    fDraft    ## D - draft
    fFlagged  ## F - flagged/starred

  Message* = object
    ## A message in a maildir
    path*: string      ## Full path to the message file
    dir*: string       ## "new" or "cur"
    uniqueName*: string ## The unique filename portion (before :2,)
    flags*: set[Flag]  ## Current flags

  Maildir* = object
    ## A maildir directory
    path*: string

const
  FlagChars: array[Flag, char] = ['P', 'R', 'S', 'T', 'D', 'F']

var counter {.global.}: int = 0

proc flagsToString*(flags: set[Flag]): string =
  ## Convert flags to the maildir info string (sorted characters after :2,)
  for f in Flag:
    if f in flags:
      result.add FlagChars[f]

proc stringToFlags*(s: string): set[Flag] =
  ## Parse a maildir flag string into a set of flags
  for c in s:
    for f in Flag:
      if FlagChars[f] == c:
        result.incl f

proc parseMessagePath*(path: string): Message =
  ## Parse a message file path into a Message object
  let (dir, name, _) = splitFile(path)
  let parentDir = lastPathPart(dir)
  let fullName = name & (if splitFile(path).ext.len > 0: splitFile(path).ext else: "")

  var uniqueName = extractFilename(path)
  var flags: set[Flag] = {}

  let colonPos = uniqueName.find(":2,")
  if colonPos >= 0:
    let flagStr = uniqueName[colonPos + 3 .. ^1]
    flags = stringToFlags(flagStr)
    uniqueName = uniqueName[0 ..< colonPos]

  result = Message(
    path: path,
    dir: parentDir,
    uniqueName: uniqueName,
    flags: flags
  )

proc generateUniqueName*(): string =
  ## Generate a unique filename per the maildir spec:
  ## time.pid.hostname with a process-local counter for uniqueness
  let t = epochTime()
  let secs = int(t)
  let usecs = int((t - float(secs)) * 1_000_000)
  let pid = getCurrentProcessId()
  var hostname = newString(256)
  discard getHostname(cstring(hostname), 256)
  hostname.setLen(hostname.cstring.len)
  inc counter
  result = $secs & ".M" & $usecs & "P" & $pid & "Q" & $counter & "." & hostname

proc init*(path: string): Maildir =
  ## Create a new maildir at the given path, creating the directory structure
  ## if it doesn't exist. Returns the Maildir object.
  result = Maildir(path: path)
  createDir(path / "tmp")
  createDir(path / "new")
  createDir(path / "cur")

proc openMaildir*(path: string): Maildir =
  ## Open an existing maildir. Raises if the directory structure is missing.
  if not dirExists(path / "tmp") or not dirExists(path / "new") or not dirExists(path / "cur"):
    raise newException(IOError, "Not a valid maildir: " & path)
  result = Maildir(path: path)

proc parseHeaders(content: string): OrderedTable[string, string] =
  ## Parse email headers from content. Returns header names lowercased as keys.
  ## Handles continuation lines (lines starting with whitespace).
  result = initOrderedTable[string, string]()
  var currentKey = ""
  for line in content.splitLines():
    if line.len == 0:
      break  # empty line = end of headers
    if line[0] in {' ', '\t'} and currentKey.len > 0:
      # continuation line
      result[currentKey] &= "\n" & line
    else:
      let colonPos = line.find(':')
      if colonPos < 0:
        break  # not a header line, treat as body start
      currentKey = line[0 ..< colonPos].strip().toLowerAscii()
      let value = line[colonPos + 1 .. ^1].strip()
      result[currentKey] = value

proc hasHeader(content: string, name: string): bool =
  ## Check if a header exists in the message content.
  let headers = parseHeaders(content)
  name.toLowerAscii() in headers

proc addMissingHeaders(content: string, uniqueName: string): string =
  ## Add default headers that aren't already present. Never overrides existing.
  var headers = parseHeaders(content)
  var toAdd: seq[string]

  # Generate Message-ID if missing
  if "message-id" notin headers:
    var hostname = newString(256)
    discard getHostname(cstring(hostname), 256)
    hostname.setLen(hostname.cstring.len)
    toAdd.add "Message-ID: <" & uniqueName & "@" & hostname & ">"

  # Date in RFC 2822 format
  if "date" notin headers:
    let now = now().utc()
    toAdd.add "Date: " & now.format("ddd, dd MMM yyyy HH:mm:ss") & " +0000"

  # MIME headers
  if "mime-version" notin headers:
    toAdd.add "MIME-Version: 1.0"
  if "content-type" notin headers:
    toAdd.add "Content-Type: text/plain; charset=utf-8"
  if "content-transfer-encoding" notin headers:
    toAdd.add "Content-Transfer-Encoding: 8bit"

  if toAdd.len == 0:
    return content

  # Insert defaults after existing headers, before the blank line
  let blankPos = content.find("\n\n")
  if blankPos >= 0:
    result = content[0 ..< blankPos] & "\n" & toAdd.join("\n") & content[blankPos .. ^1]
  else:
    # No blank line found — all headers, no body
    result = content & "\n" & toAdd.join("\n") & "\n\n"

proc validateHeaders*(content: string) =
  ## Validate that required headers are present. Raises ValueError if not.
  let headers = parseHeaders(content)
  if "from" notin headers:
    raise newException(ValueError, "Missing required header: From")
  if "to" notin headers:
    raise newException(ValueError, "Missing required header: To")

proc deliver*(md: Maildir, content: string): Message =
  ## Deliver a message to the maildir. Validates that From and To headers
  ## are present, adds default headers (Date, MIME-Version, Content-Type,
  ## Content-Transfer-Encoding, Message-ID) if missing, then writes to tmp/
  ## and atomically moves to new/. Returns the resulting Message.
  validateHeaders(content)
  let name = generateUniqueName()
  let prepared = addMissingHeaders(content, name)
  let tmpPath = md.path / "tmp" / name
  let newPath = md.path / "new" / name
  writeFile(tmpPath, prepared)
  moveFile(tmpPath, newPath)
  result = parseMessagePath(newPath)

proc list*(md: Maildir, dir: string = ""): seq[Message] =
  ## List messages. If dir is "" list both new and cur.
  ## If dir is "new" or "cur", list only that directory.
  var dirs: seq[string]
  if dir == "":
    dirs = @["new", "cur"]
  else:
    dirs = @[dir]

  for d in dirs:
    let dirPath = md.path / d
    if dirExists(dirPath):
      for kind, path in walkDir(dirPath):
        if kind == pcFile:
          result.add parseMessagePath(path)

  result.sort proc(a, b: Message): int =
    cmp(a.uniqueName, b.uniqueName)

proc read*(msg: Message): string =
  ## Read the content of a message
  readFile(msg.path)

proc get*(md: Maildir, uniqueName: string): Message =
  ## Find a message by its unique name (or prefix). Searches new/ then cur/.
  for d in ["new", "cur"]:
    let dirPath = md.path / d
    if dirExists(dirPath):
      for kind, path in walkDir(dirPath):
        if kind == pcFile:
          let m = parseMessagePath(path)
          if m.uniqueName == uniqueName or m.uniqueName.startsWith(uniqueName):
            return m
  raise newException(KeyError, "Message not found: " & uniqueName)

proc setFlags*(md: Maildir, msg: Message, flags: set[Flag]): Message =
  ## Set the flags on a message. Moves it to cur/ if in new/.
  ## Returns the updated Message.
  let flagStr = flagsToString(flags)
  let newName = msg.uniqueName & ":2," & flagStr
  let destPath = md.path / "cur" / newName
  if msg.path != destPath:
    moveFile(msg.path, destPath)
  result = parseMessagePath(destPath)

proc markSeen*(md: Maildir, msg: Message): Message =
  ## Mark a message as seen (read). Convenience for adding the Seen flag.
  setFlags(md, msg, msg.flags + {fSeen})

proc markFlagged*(md: Maildir, msg: Message): Message =
  ## Mark a message as flagged/starred.
  setFlags(md, msg, msg.flags + {fFlagged})

proc markReplied*(md: Maildir, msg: Message): Message =
  ## Mark a message as replied to.
  setFlags(md, msg, msg.flags + {fReplied})

proc process*(md: Maildir, msg: Message): Message =
  ## Move a message from new/ to cur/ without changing flags.
  ## No-op if already in cur/.
  if msg.dir == "cur":
    return msg
  setFlags(md, msg, msg.flags)

proc delete*(md: Maildir, msg: Message) =
  ## Delete a message from the maildir.
  removeFile(msg.path)

proc purge*(md: Maildir) =
  ## Delete all messages flagged as trashed.
  for msg in md.list("cur"):
    if fTrashed in msg.flags:
      removeFile(msg.path)

proc trash*(md: Maildir, msg: Message): Message =
  ## Mark a message as trashed.
  setFlags(md, msg, msg.flags + {fTrashed})

proc count*(md: Maildir): tuple[newMsgs: int, curMsgs: int] =
  ## Count messages in new/ and cur/.
  for kind, _ in walkDir(md.path / "new"):
    if kind == pcFile: inc result.newMsgs
  for kind, _ in walkDir(md.path / "cur"):
    if kind == pcFile: inc result.curMsgs

proc cleanTmp*(md: Maildir, maxAge: Duration = initDuration(hours = 36)) =
  ## Remove stale files from tmp/ older than maxAge (default 36 hours per spec).
  let now = getTime()
  for kind, path in walkDir(md.path / "tmp"):
    if kind == pcFile:
      let info = getFileInfo(path)
      if now - info.lastWriteTime > maxAge:
        removeFile(path)
