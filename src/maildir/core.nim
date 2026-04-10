## maildir/core - Maildir format operations
##
## Implements the Maildir specification (https://cr.yp.to/proto/mailstruc.html):
## - Three subdirectories: tmp, new, cur
## - Unique filenames using timestamp, pid, hostname, and a counter
## - Atomic delivery via tmp -> new rename
## - Flags encoded in filename suffix after `:2,`

import std/[os, times, strutils, algorithm, posix, tables, base64]

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

  Attachment* = object
    ## An email attachment
    filename*: string
    contentType*: string
    data*: string

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

proc generateBoundary(): string =
  ## Generate a unique MIME boundary string
  let t = epochTime()
  let secs = int(t)
  let usecs = int((t - float(secs)) * 1_000_000)
  inc counter
  result = "----=_maildir_" & $secs & "." & $usecs & "." & $counter

proc wrapBase64(encoded: string, lineLen: int = 76): string =
  ## Wrap base64 encoded string to specified line length per RFC 2045
  var i = 0
  while i < encoded.len:
    let endPos = min(i + lineLen, encoded.len)
    if result.len > 0:
      result.add "\n"
    result.add encoded[i ..< endPos]
    i = endPos

proc buildMultipart(content: string, attachments: seq[Attachment]): string =
  ## Build a multipart/mixed message from content and attachments.
  ## Moves any Content-Type and Content-Transfer-Encoding from the top-level
  ## headers into the first MIME part (the message body).
  let boundary = generateBoundary()

  # Split into headers and body
  let blankPos = content.find("\n\n")
  var origHeaders, origBody: string
  if blankPos >= 0:
    origHeaders = content[0 ..< blankPos]
    origBody = content[blankPos + 2 .. ^1]
  else:
    origHeaders = content
    origBody = ""

  # Get body part content-type from original headers
  let parsed = parseHeaders(content)
  var bodyContentType = "text/plain; charset=utf-8"
  var bodyEncoding = "8bit"
  if "content-type" in parsed:
    bodyContentType = parsed["content-type"]
  if "content-transfer-encoding" in parsed:
    bodyEncoding = parsed["content-transfer-encoding"]

  # Rebuild top-level headers without content-type and content-transfer-encoding
  var newHeaders: seq[string]
  var skipCont = false
  for line in origHeaders.splitLines():
    if line.len > 0 and line[0] in {' ', '\t'}:
      if not skipCont:
        newHeaders.add line
      continue
    let lower = line.toLowerAscii()
    if lower.startsWith("content-type:") or lower.startsWith("content-transfer-encoding:"):
      skipCont = true
    else:
      skipCont = false
      newHeaders.add line

  result = newHeaders.join("\n")
  result &= "\nContent-Type: multipart/mixed; boundary=\"" & boundary & "\""
  result &= "\n\n"

  # Body part
  result &= "--" & boundary & "\n"
  result &= "Content-Type: " & bodyContentType & "\n"
  result &= "Content-Transfer-Encoding: " & bodyEncoding & "\n"
  result &= "\n"
  result &= origBody & "\n"

  # Attachment parts
  for att in attachments:
    result &= "--" & boundary & "\n"
    result &= "Content-Type: " & att.contentType
    if att.filename.len > 0:
      result &= "; name=\"" & att.filename & "\""
    result &= "\n"
    if att.filename.len > 0:
      result &= "Content-Disposition: attachment; filename=\"" & att.filename & "\"\n"
    result &= "Content-Transfer-Encoding: base64\n"
    result &= "\n"
    result &= wrapBase64(encode(att.data)) & "\n"

  result &= "--" & boundary & "--\n"

proc deliver*(md: Maildir, content: string, attachments: seq[Attachment] = @[]): Message =
  ## Deliver a message to the maildir. Validates that From and To headers
  ## are present, adds default headers (Date, MIME-Version, Content-Type,
  ## Content-Transfer-Encoding, Message-ID) if missing, then writes to tmp/
  ## and atomically moves to new/. Returns the resulting Message.
  validateHeaders(content)
  let name = generateUniqueName()
  let prepared = if attachments.len > 0:
                   addMissingHeaders(buildMultipart(content, attachments), name)
                 else:
                   addMissingHeaders(content, name)
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

proc parseBoundary(content: string): string =
  ## Extract the boundary string from a multipart Content-Type header
  let headers = parseHeaders(content)
  if "content-type" in headers:
    let ct = headers["content-type"]
    let bpos = ct.find("boundary=")
    if bpos >= 0:
      var b = ct[bpos + 9 .. ^1]
      if b.startsWith("\""):
        let endQ = b.find("\"", 1)
        if endQ >= 0:
          b = b[1 ..< endQ]
      else:
        let endPos = b.find({';', ' ', '\t', '\n', '\r'})
        if endPos >= 0:
          b = b[0 ..< endPos]
      return b

proc parseMimeParts(content: string): seq[string] =
  ## Split a multipart message into its MIME parts (excluding preamble and epilogue)
  let boundary = parseBoundary(content)
  if boundary.len == 0:
    return @[]
  let delim = "--" & boundary
  let parts = content.split(delim)
  for i in 1 ..< parts.len:
    let part = parts[i]
    if part.startsWith("--"):
      break
    # Strip the leading newline after the boundary line
    result.add(if part.startsWith("\r\n"): part[2..^1]
               elif part.startsWith("\n"): part[1..^1]
               else: part)

proc extractFilename(header: string): string =
  ## Extract filename from Content-Disposition or Content-Type header value
  for prefix in ["filename=", "name="]:
    let pos = header.find(prefix)
    if pos >= 0:
      var name = header[pos + prefix.len .. ^1]
      if name.startsWith("\""):
        let endQ = name.find("\"", 1)
        if endQ >= 0:
          return name[1 ..< endQ]
      else:
        let endPos = name.find({';', ' ', '\t', '\n', '\r'})
        if endPos >= 0:
          return name[0 ..< endPos]
        return name

proc listAttachments*(content: string): seq[Attachment] =
  ## List attachments in a message. Returns Attachment objects with empty data.
  let parts = parseMimeParts(content)
  if parts.len <= 1:
    return @[]

  for i in 1 ..< parts.len:
    let headers = parseHeaders(parts[i])
    var filename = ""
    var contentType = "application/octet-stream"

    if "content-disposition" in headers:
      filename = extractFilename(headers["content-disposition"])
    if "content-type" in headers:
      let ct = headers["content-type"]
      if filename.len == 0:
        filename = extractFilename(ct)
      let semiPos = ct.find(";")
      contentType = if semiPos >= 0: ct[0 ..< semiPos].strip() else: ct.strip()

    result.add Attachment(filename: filename, contentType: contentType, data: "")

proc extractAttachment*(content: string, index: int): Attachment =
  ## Extract an attachment by 0-based index. Returns Attachment with decoded data.
  let parts = parseMimeParts(content)
  if parts.len <= 1:
    raise newException(ValueError, "No attachments in message")
  let partIdx = index + 1  # skip body part
  if partIdx >= parts.len:
    raise newException(IndexDefect, "Attachment index out of range: " & $index)

  let part = parts[partIdx]
  let headers = parseHeaders(part)

  # Get body of this part
  let bodyPos = part.find("\n\n")
  if bodyPos < 0:
    raise newException(ValueError, "Malformed MIME part")
  let body = part[bodyPos + 2 .. ^1]

  var filename = ""
  var contentType = "application/octet-stream"
  var isBase64 = false

  if "content-disposition" in headers:
    filename = extractFilename(headers["content-disposition"])
  if "content-type" in headers:
    let ct = headers["content-type"]
    if filename.len == 0:
      filename = extractFilename(ct)
    let semiPos = ct.find(";")
    contentType = if semiPos >= 0: ct[0 ..< semiPos].strip() else: ct.strip()
  if "content-transfer-encoding" in headers:
    isBase64 = headers["content-transfer-encoding"].strip().toLowerAscii() == "base64"

  let data = if isBase64: decode(body.strip()) else: body
  result = Attachment(filename: filename, contentType: contentType, data: data)

proc extractAttachment*(content: string, filename: string): Attachment =
  ## Extract an attachment by filename.
  let attachments = listAttachments(content)
  for i, att in attachments:
    if att.filename == filename:
      return extractAttachment(content, i)
  raise newException(KeyError, "Attachment not found: " & filename)
