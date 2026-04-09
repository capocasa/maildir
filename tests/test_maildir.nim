import std/[os, strutils, unittest]
import maildir

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
      discard open(testDir / "nonexistent")

  test "deliver writes to new/":
    let md = init(testDir)
    let msg = md.deliver("Subject: Test\n\nHello")
    check msg.dir == "new"
    check fileExists(msg.path)
    check msg.read() == "Subject: Test\n\nHello"

  test "list messages":
    let md = init(testDir)
    discard md.deliver("msg1")
    discard md.deliver("msg2")
    let msgs = md.list()
    check msgs.len == 2

  test "list by directory":
    let md = init(testDir)
    discard md.deliver("msg1")
    check md.list("new").len == 1
    check md.list("cur").len == 0

  test "get by unique name":
    let md = init(testDir)
    let msg = md.deliver("test")
    let found = md.get(msg.uniqueName)
    check found.uniqueName == msg.uniqueName

  test "get by prefix":
    let md = init(testDir)
    let msg = md.deliver("test")
    let prefix = msg.uniqueName[0..5]
    let found = md.get(prefix)
    check found.uniqueName == msg.uniqueName

  test "markSeen moves to cur with S flag":
    let md = init(testDir)
    let msg = md.deliver("test")
    let seen = md.markSeen(msg)
    check seen.dir == "cur"
    check fSeen in seen.flags

  test "markFlagged":
    let md = init(testDir)
    let msg = md.deliver("test")
    let flagged = md.markFlagged(msg)
    check fFlagged in flagged.flags

  test "setFlags preserves existing flags":
    let md = init(testDir)
    let msg = md.deliver("test")
    let seen = md.markSeen(msg)
    let both = md.markFlagged(seen)
    check fSeen in both.flags
    check fFlagged in both.flags

  test "process moves from new to cur":
    let md = init(testDir)
    let msg = md.deliver("test")
    check msg.dir == "new"
    let processed = md.process(msg)
    check processed.dir == "cur"

  test "delete removes file":
    let md = init(testDir)
    let msg = md.deliver("test")
    md.delete(msg)
    check not fileExists(msg.path)
    check md.list().len == 0

  test "trash and purge":
    let md = init(testDir)
    let msg = md.deliver("test")
    let trashed = md.trash(msg)
    check fTrashed in trashed.flags
    check md.list().len == 1
    md.purge()
    check md.list().len == 0

  test "count":
    let md = init(testDir)
    discard md.deliver("msg1")
    discard md.deliver("msg2")
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
