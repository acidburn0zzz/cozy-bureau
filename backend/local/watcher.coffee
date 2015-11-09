chokidar = require 'chokidar'
crypto   = require 'crypto'
fs       = require 'fs'
mime     = require 'mime'
path     = require 'path'
log      = require('printit')
    prefix: 'Local watcher '


# This file contains the filesystem watcher that will trigger operations when
# a file or a folder is added/removed/changed locally.
# Operations will be added to the a common operation queue along with the
# remote operations triggered by the remoteEventWatcher.
#
# TODO find deleted files/folders in the initial scan
# TODO detects move/rename:
# TODO - https://github.com/paulmillr/chokidar/issues/303#issuecomment-127039892
# TODO - Inotify.IN_MOVED_FROM & Inotify.IN_MOVED_TO
# TODO - track inodes
class LocalWatcher

    constructor: (@basePath, @merge, @pouch, @events) ->

    # Start chokidar, the filesystem watcher
    # https://github.com/paulmillr/chokidar
    #
    # The callback is called when the initial scan is complete
    start: (callback) =>
        log.info 'Start watching filesystem for changes'

        @watcher = chokidar.watch '.',
            # Let paths in events be relative to this base path
            cwd: @basePath
            # Ignore our own .cozy-desktop directory
            ignored: /[\/\\]\.cozy-desktop/
            # Don't follow symlinks
            followSymlinks: false
            # The stats object is used in methods below
            alwaysStat: true
            # Filter out artifacts from editors with atomic writes
            atomic: true
            # Poll newly created files to detect when the write is finished
            awaitWriteFinish:
                pollInterval: 100
                stabilityThreshold: 1000
            # With node 0.10 on linux, only polling is available
            interval: 1000
            binaryInterval: 2000

        @watcher
            .on 'add', @onAdd
            .on 'addDir', @onAddDir
            .on 'change', @onChange
            .on 'unlink', @onUnlink
            .on 'unlinkDir', @onUnlinkDir
            .on 'ready', callback
            .on 'error', (err) -> log.error err


    ### Helpers ###

    # An helper to create a document for a file
    createDoc: (filePath, stats, callback) =>
        absPath = path.join @basePath, filePath
        [mimeType, fileClass] = @getFileClass absPath
        @checksum absPath, (err, checksum) ->
            doc =
                _id: filePath
                docType: 'file'
                checksum: checksum
                creationDate: stats.ctime
                lastModification: stats.mtime
                size: stats.size
                class: fileClass
                mime: mimeType
            callback err, doc

    # Return mimetypes and class (like in classification) of a file.
    # ex: pic.png returns 'image/png' and 'image'.
    getFileClass: (filename, callback) ->
        mimeType = mime.lookup filename
        fileClass = switch mimeType.split('/')[0]
            when 'image'       then "image"
            when 'application' then "document"
            when 'text'        then "document"
            when 'audio'       then "music"
            when 'video'       then "video"
            else                    "file"
        return [mimeType, fileClass]

    # Get checksum for given file.
    checksum: (filePath, callback) ->
        stream = fs.createReadStream filePath
        checksum = crypto.createHash 'sha1'
        checksum.setEncoding 'hex'

        stream.on 'end', ->
            checksum.end()
            callback null, checksum.read()
        stream.on 'error', (err) ->
            checksum.end()
            callback err

        stream.pipe checksum


    ### Actions ###

    # New file detected
    # TODO pouchdb -> detect updates/conflicts
    onAdd: (filePath, stats) =>
        log.debug 'File added', filePath
        @createDoc filePath, stats, (err, doc) =>
            if err
                log.debug err
            else
                @merge.putFile doc, @done

    # New directory detected
    # TODO pouchdb -> detect updates/conflicts
    onAddDir: (folderPath, stats) =>
        unless folderPath is ''
            log.debug 'Folder added', folderPath
            doc =
                _id: folderPath
                docType: 'folder'
                creationDate: stats.ctime
                lastModification: stats.mtime
            @merge.putFolder doc, @done

    # File deletion detected
    onUnlink: (filePath) =>
        log.debug 'File deleted', filePath
        @merge.deleteFile _id: filePath, @done

    # Folder deletion detected
    onUnlinkDir: (folderPath) =>
        log.debug 'Folder deleted', folderPath
        @merge.deleteFolder _id: folderPath, @done

    # File update detected
    # TODO pouchdb -> detect updates/conflicts
    onChange: (filePath, stats) =>
        log.debug 'File updated', filePath
        @createDoc filePath, stats, (err, doc) =>
            if err
                log.debug err
            else
                @merge.putFile doc, @done

    # A callback that logs errors
    done: (err) ->
        log.error err if err


module.exports = LocalWatcher
