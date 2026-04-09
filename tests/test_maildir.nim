import std/[os, strutils, unittest]
import maildir

const validMsg = "From: sender@example.com\nTo: recipient@example.com\nSubject: Test\n\nHello"

proc minimalMsg(body: string = "Hello"): string =
  "From: sender@example.com\nTo: recipient@example.com\n\n" & body

suite "maildir":
  let testDir = getTempDir() / "test_maildir_" & $getCurrentProcessId()

  setup:
    removeDir(testDir)

  teardown:
    removeDir(testDir)

  test "init creates directory structure":
    let md = init(testDir)
    check dirExists(testDir / "tmp")
    check dirExists(testDir / "new")
    check dirExists(testDir / "cur")

  test "open validates structure":
    expect IOError:
      discard openMaildir(testDir / "nonexistent")

  test "deliver writes to new/":
    let md = init(testDir)
    let msg = md.deliver(validMsg)
    check msg.dir == "new"
    check fileExists(msg.path)

  test "list messages":
    let md = init(testDir)
    discard md.deliver(minimalMsg("msg1"))
    discard md.deliver(minimalMsg("msg2"))
    let msgs = md.list()
    check msgs.len == 2

  test "list by directory":
    let md = init(testDir)
    discard md.deliver(minimalMsg())
    check md.list("new").len == 1
    check md.list("cur").len == 0

  test "get by unique name":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let found = md.get(msg.uniqueName)
    check found.uniqueName == msg.uniqueName

  test "get by prefix":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let prefix = msg.uniqueName[0..5]
    let found = md.get(prefix)
    check found.uniqueName == msg.uniqueName

  test "markSeen moves to cur with S flag":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let seen = md.markSeen(msg)
    check seen.dir == "cur"
    check fSeen in seen.flags

  test "markFlagged":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let flagged = md.markFlagged(msg)
    check fFlagged in flagged.flags

  test "setFlags preserves existing flags":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let seen = md.markSeen(msg)
    let both = md.markFlagged(seen)
    check fSeen in both.flags
    check fFlagged in both.flags

  test "process moves from new to cur":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    check msg.dir == "new"
    let processed = md.process(msg)
    check processed.dir == "cur"

  test "delete removes file":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    md.delete(msg)
    check not fileExists(msg.path)
    check md.list().len == 0

  test "trash and purge":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let trashed = md.trash(msg)
    check fTrashed in trashed.flags
    check md.list().len == 1
    md.purge()
    check md.list().len == 0

  test "count":
    let md = init(testDir)
    discard md.deliver(minimalMsg("msg1"))
    discard md.deliver(minimalMsg("msg2"))
    let c = md.count()
    check c.newMsgs == 2
    check c.curMsgs == 0

  test "flags roundtrip":
    let flags = {fSeen, fFlagged, fReplied}
    let s = flagsToString(flags)
    let parsed = stringToFlags(s)
    check parsed == flags

  test "flag string is sorted":
    let s = flagsToString({fTrashed, fSeen, fPassed})
    check s == "PST"

suite "headers":
  let testDir = getTempDir() / "test_maildir_headers_" & $getCurrentProcessId()

  setup:
    removeDir(testDir)

  teardown:
    removeDir(testDir)

  test "deliver rejects missing From":
    let md = init(testDir)
    expect ValueError:
      discard md.deliver("To: recipient@example.com\n\nHello")

  test "deliver rejects missing To":
    let md = init(testDir)
    expect ValueError:
      discard md.deliver("From: sender@example.com\n\nHello")

  test "deliver rejects no headers at all":
    let md = init(testDir)
    expect ValueError:
      discard md.deliver("Just a body")

  test "deliver adds Date header":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let content = msg.read()
    check "Date: " in content

  test "deliver adds MIME-Version header":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let content = msg.read()
    check "MIME-Version: 1.0" in content

  test "deliver adds Content-Type header":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let content = msg.read()
    check "Content-Type: text/plain; charset=utf-8" in content

  test "deliver adds Content-Transfer-Encoding header":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let content = msg.read()
    check "Content-Transfer-Encoding: 8bit" in content

  test "deliver adds Message-ID header":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let content = msg.read()
    check "Message-ID: <" in content

  test "deliver does not override existing Date":
    let md = init(testDir)
    let custom = "From: a@b.com\nTo: c@d.com\nDate: Thu, 01 Jan 2030 00:00:00 +0000\n\nHello"
    let msg = md.deliver(custom)
    let content = msg.read()
    check "Thu, 01 Jan 2030 00:00:00 +0000" in content
    # Should appear only once
    check content.count("Date: ") == 1

  test "deliver does not override existing MIME-Version":
    let md = init(testDir)
    let custom = "From: a@b.com\nTo: c@d.com\nMIME-Version: 2.0\n\nHello"
    let msg = md.deliver(custom)
    let content = msg.read()
    check "MIME-Version: 2.0" in content
    check content.count("MIME-Version: ") == 1

  test "deliver does not override existing Content-Type":
    let md = init(testDir)
    let custom = "From: a@b.com\nTo: c@d.com\nContent-Type: text/html; charset=iso-8859-1\n\nHello"
    let msg = md.deliver(custom)
    let content = msg.read()
    check "text/html; charset=iso-8859-1" in content
    check content.count("Content-Type: ") == 1

  test "deliver does not override existing Content-Transfer-Encoding":
    let md = init(testDir)
    let custom = "From: a@b.com\nTo: c@d.com\nContent-Transfer-Encoding: base64\n\nHello"
    let msg = md.deliver(custom)
    let content = msg.read()
    check "Content-Transfer-Encoding: base64" in content
    check content.count("Content-Transfer-Encoding: ") == 1

  test "deliver does not override existing Message-ID":
    let md = init(testDir)
    let custom = "From: a@b.com\nTo: c@d.com\nMessage-ID: <custom@example.com>\n\nHello"
    let msg = md.deliver(custom)
    let content = msg.read()
    check "<custom@example.com>" in content
    check content.count("Message-ID: ") == 1

  test "deliver preserves body after defaults injection":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg("This is the body\nWith multiple lines"))
    let content = msg.read()
    check "This is the body\nWith multiple lines" in content

  test "header parsing is case-insensitive":
    let md = init(testDir)
    let custom = "from: a@b.com\nto: c@d.com\ncontent-type: text/html\n\nHello"
    let msg = md.deliver(custom)
    let content = msg.read()
    # Should not add a second Content-Type (case-insensitive match)
    check content.toLowerAscii().count("content-type") == 1
    # The lowercase original should be preserved as-is
    check "content-type: text/html" in content

  test "deliver works with all headers already present":
    let md = init(testDir)
    let full = "From: a@b.com\nTo: c@d.com\nDate: Thu, 01 Jan 2030 00:00:00 +0000\nMIME-Version: 1.0\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit\nMessage-ID: <test@example.com>\n\nBody"
    let msg = md.deliver(full)
    let content = msg.read()
    check content == full

  test "deliver with Subject does not require it":
    let md = init(testDir)
    let msg = md.deliver(minimalMsg())
    let content = msg.read()
    # No Subject was added
    check "Subject: " notin content
