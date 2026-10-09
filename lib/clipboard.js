// Run only for an explicit clipboard transfer or guest-local paste command.
ObjC.import('AppKit');

function run(args) {
    if (args.length !== 1 || ['read', 'write'].indexOf(args[0]) < 0)
        throw new Error('Expected read or write.');
    var limit = 1024 * 1024;
    var board = $.NSPasteboard.generalPasteboard;
    if (args[0] === 'read') {
        var value = board.stringForType($.NSPasteboardTypeString);
        if (value.isNil()) return JSON.stringify({error: 'no-text'});
        if (value.lengthOfBytesUsingEncoding($.NSUTF8StringEncoding) > limit)
            return JSON.stringify({error: 'too-large'});
        return JSON.stringify({text: ObjC.unwrap(value)});
    }
    var data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    var payload = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding)));
    if (typeof payload.text !== 'string') throw new Error('Expected text.');
    var text = $(payload.text);
    if (text.lengthOfBytesUsingEncoding($.NSUTF8StringEncoding) > limit)
        return JSON.stringify({error: 'too-large'});
    // Set the string type explicitly: text resembling RTF or PostScript must
    // remain literal text, with no rich data, file URLs or promised files.
    board.clearContents;
    return JSON.stringify({ok: Boolean(board.setStringForType(text, $.NSPasteboardTypeString))});
}
