## maildir - Maildir library and CLI tool
##
## Library usage:
##   import maildir
##   let md = init("/path/to/maildir")
##   let msg = md.deliver("From: ...\nSubject: ...\n\nBody")
##   for m in md.list(): echo m.uniqueName
##
## CLI usage:
##   maildir init /path/to/maildir
##   maildir deliver /path/to/maildir < message.eml
##   maildir list /path/to/maildir
##   maildir read /path/to/maildir <unique-name>

import std/[strutils, sequtils]
import maildir/core

export core

const
  Version = staticRead("../maildir.nimble").splitLines().filterIt(it.startsWith("version")).
    mapIt(it.split("=")[1].strip().strip(chars = {'"'}))[0]

when isMainModule:
  import cligen

  proc initCmd(path: string): int =
    ## Create a new maildir directory structure
    try:
      discard init(path)
      echo "Created maildir: ", path
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc deliverCmd(path: string, message: string = ""): int =
    ## Deliver a message to a maildir. Reads from stdin if no message given.
    try:
      let md = openMaildir(path)
      let content = if message.len > 0: message
                    else: stdin.readAll()
      let msg = md.deliver(content)
      echo msg.uniqueName
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc listCmd(path: string, newOnly: bool = false, curOnly: bool = false,
               count: bool = false): int =
    ## List messages in a maildir
    try:
      let md = openMaildir(path)
      if count:
        let c = md.count()
        echo c.newMsgs, " new, ", c.curMsgs, " cur"
        return 0
      let dir = if newOnly: "new" elif curOnly: "cur" else: ""
      for msg in md.list(dir):
        var info = msg.dir & "/" & msg.uniqueName
        let flags = flagsToString(msg.flags)
        if flags.len > 0:
          info.add " [" & flags & "]"
        echo info
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc readCmd(path: string, name: string): int =
    ## Read a message from a maildir by unique name (or prefix)
    try:
      let md = openMaildir(path)
      let msg = md.get(name)
      stdout.write msg.read()
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc flagCmd(path: string, name: string, seen: bool = false,
               flagged: bool = false, replied: bool = false,
               trashed: bool = false, draft: bool = false,
               passed: bool = false): int =
    ## Set flags on a message
    try:
      let md = openMaildir(path)
      var msg = md.get(name)
      var flags = msg.flags
      if seen: flags.incl fSeen
      if flagged: flags.incl fFlagged
      if replied: flags.incl fReplied
      if trashed: flags.incl fTrashed
      if draft: flags.incl fDraft
      if passed: flags.incl fPassed
      msg = md.setFlags(msg, flags)
      echo msg.dir, "/", msg.uniqueName, " [", flagsToString(msg.flags), "]"
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc deleteCmd(path: string, name: string): int =
    ## Delete a message from a maildir
    try:
      let md = openMaildir(path)
      let msg = md.get(name)
      md.delete(msg)
      echo "Deleted: ", name
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc purgeCmd(path: string): int =
    ## Delete all messages flagged as trashed
    try:
      let md = openMaildir(path)
      md.purge()
      echo "Purged trashed messages"
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc cleanCmd(path: string): int =
    ## Remove stale files from tmp/
    try:
      let md = openMaildir(path)
      md.cleanTmp()
      echo "Cleaned tmp/"
    except:
      stderr.writeLine "Error: ", getCurrentExceptionMsg()
      return 1

  proc versionCmd(): int =
    ## Show version
    echo "maildir ", Version
    return 0

  dispatchMulti(
    [initCmd, cmdName = "init", help = {
      "path": "Path to create maildir at"
    }],
    [deliverCmd, cmdName = "deliver", help = {
      "path": "Path to maildir",
      "message": "Message content (reads stdin if empty)"
    }],
    [listCmd, cmdName = "list", help = {
      "path": "Path to maildir",
      "newOnly": "List only new/ messages",
      "curOnly": "List only cur/ messages",
      "count": "Show message counts only"
    }],
    [readCmd, cmdName = "read", help = {
      "path": "Path to maildir",
      "name": "Unique name or prefix of message"
    }],
    [flagCmd, cmdName = "flag", help = {
      "path": "Path to maildir",
      "name": "Unique name or prefix of message",
      "seen": "Mark as seen/read",
      "flagged": "Mark as flagged/starred",
      "replied": "Mark as replied",
      "trashed": "Mark as trashed",
      "draft": "Mark as draft",
      "passed": "Mark as forwarded"
    }],
    [deleteCmd, cmdName = "delete", help = {
      "path": "Path to maildir",
      "name": "Unique name or prefix of message"
    }],
    [purgeCmd, cmdName = "purge", help = {
      "path": "Path to maildir"
    }],
    [cleanCmd, cmdName = "clean", help = {
      "path": "Path to maildir"
    }],
    [versionCmd, cmdName = "version"]
  )
