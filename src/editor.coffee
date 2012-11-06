#= require underscore
#= require rangy/rangy-core
#= require diff_match_patch
#= require eventemitter2
#= require tandem/document
#= require tandem/range
#= require tandem/keyboard
#= require tandem/selection
#= require tandem/renderer

stripNewlineAttributes = (delta) ->
  deltas = []
  _.each(delta.deltas, (delta) ->
    if delta.text?
      texts = delta.text.split("\n")
      _.each(texts, (text, index) ->
        deltas.push(new JetInsert(text, _.clone(delta.attributes)))
        deltas.push(new JetInsert("\n")) if index < texts.length - 1
      )
    else
      deltas.push(delta)
  )
  delta = new JetDelta(delta.startLength, delta.endLength, deltas)
  delta.compact()
  return delta


class TandemEditor extends EventEmitter2
  @editors: []

  @CONTAINER_ID: 'tandem-container'
  @ID_PREFIX: 'editor-'
  @CURSOR_PREFIX: 'cursor-'
  @DEFAULTS:
    cursor: 0
    enabled: true
    styles: {}

  @events: 
    API_TEXT_CHANGE       : 'api-text-change'
    USER_SELECTION_CHANGE : 'user-selection-change'
    USER_TEXT_CHANGE      : 'user-text-change'

  constructor: (@iframeContainer, options) ->
    @options = _.extend(Tandem.Editor.DEFAULTS, options)
    @id = _.uniqueId(TandemEditor.ID_PREFIX)
    @iframeContainer = document.getElementById(@iframeContainer) if _.isString(@iframeContainer)
    @destructors = []
    @cursors = {}
    this.reset(true)
    @cursorContainer = @doc.root.ownerDocument.getElementById('cursor-container')
    this.enable() if @options.enabled


  applyDeltaToCursors: (delta) ->
    JetState.applyDelta(delta, ((index, text) =>
      this.shiftCursors(index, text.length)
    ), ((start, end) =>
      this.shiftCursors(start, start-end)
    ))

  shiftCursors: (index, length) ->
    for id,cursor of @cursors
      if cursor == undefined || cursor.index < index
        continue
      if (cursor.index > index)
        if length > 0
          this.setCursor(cursor.userId, cursor.index + length, cursor.name, cursor.color)   # Insert
        else
          # Delete needs to handle special case: start|cursor|end vs normal case: start|end|cursor
          this.setCursor(cursor.userId, cursor.index + Math.max(length, index - cursor.index), cursor.name, cursor.color)

  setCursor: (userId, index, name, color) ->
    cursor = @doc.root.ownerDocument.getElementById(TandemEditor.CURSOR_PREFIX + userId)
    unless cursor?
      cursor = @doc.root.ownerDocument.createElement('span')
      cursor.classList.add('cursor')
      cursor.classList.add(Tandem.Constants.SPECIAL_CLASSES.EXTERNAL)
      cursor.id = TandemEditor.CURSOR_PREFIX + userId
      inner = @doc.root.ownerDocument.createElement('span')
      inner.classList.add('cursor-inner')
      inner.classList.add(Tandem.Constants.SPECIAL_CLASSES.EXTERNAL)
      nameNode = @doc.root.ownerDocument.createElement('span')
      nameNode.classList.add('cursor-name')
      nameNode.classList.add(Tandem.Constants.SPECIAL_CLASSES.EXTERNAL)
      nameNode.textContent = name
      inner.style['background-color'] = nameNode.style['background-color'] = color
      cursor.appendChild(nameNode)
      cursor.appendChild(inner)
      @cursorContainer.appendChild(cursor)
    @cursors[userId] = {
      index: index
      name: name
      color: color
      userId: userId
    }
    position = new Tandem.Position(this, index)
    [left, right] = Tandem.Utils.splitNode(position.leafNode, position.offset)
    if right?
      cursor.style.top = right.offsetTop
      cursor.style.left = right.offsetLeft
      Tandem.Utils.mergeNodes(left, right)
    else if left?
      span = left.ownerDocument.createElement('span')
      left.parentNode.appendChild(span)
      cursor.style.top = span.offsetTop
      cursor.style.left = span.offsetLeft
      span.parentNode.removeChild(span)
    else
      console.warn "Could not set cursor"


  moveCursor: (userId, index) ->
    if @cursors[userId]
      this.setCursor(userId, index, @cursors[userId].name, @cursors[userId].color)

  clearCursors: ->
    _.each(@doc.root.querySelectorAll('.cursor'), (cursor) ->
      cursor.parentNode.removeChild(cursor)
    )

  removeCursor: (userId) ->
    cursor = @doc.root.ownerDocument.getElementById(TandemEditor.CURSOR_PREFIX + userId)
    cursor.parentNode.removeChild(cursor) if cursor?

  destroy: ->
    this.disable()
    @renderer.destroy()
    @selection.destroy()
    _.each(@destructors, (fn) =>
      fn.call(this)
    )
    @destructors = null

  reset: (keepHTML = false) ->
    @ignoreDomChanges = true
    options = _.clone(@options)
    options.keepHTML = keepHTML
    @renderer = new Tandem.Renderer(@iframeContainer, options)
    @contentWindow = @renderer.iframe.contentWindow
    @doc = new Tandem.Document(this, @contentWindow.document.getElementById(TandemEditor.CONTAINER_ID))
    @selection = new Tandem.Selection(this)
    @keyboard = new Tandem.Keyboard(this)
    this.initListeners()
    @ignoreDomChanges = false
    TandemEditor.editors.push(this)

  disable: ->
    this.trackDelta( =>
      @doc.root.setAttribute('contenteditable', false)
    , false)

  enable: ->
    if !@doc.root.getAttribute('contenteditable')
      this.trackDelta( =>
        @doc.root.setAttribute('contenteditable', true)
      , false)
      #@doc.root.focus()
      #position = Tandem.Position.makePosition(this, @options.cursor)
      #start = new Tandem.Range(this, position, position)
      #this.setSelection(start)

  initListeners: ->
    modified = false

    debouncedEdit = =>
      return unless modified
      modified = false
      return if @ignoreDomChanges or !@destructors?
      delta = this.update()
      this.emit(TandemEditor.events.USER_TEXT_CHANGE, delta) unless delta.isIdentity()

    onEdit = =>
      return if @ignoreDomChanges or !@destructors?
      debouncedEdit()

    onSubtreeModified = =>
      return if @ignoreDomChanges or !@destructors?
      modified = true

    interval = setInterval(onEdit, 500)
    @doc.root.addEventListener('DOMSubtreeModified', onSubtreeModified)
    @destructors.push( ->
      @doc.root.removeEventListener('DOMSubtreeModified', onSubtreeModified)
      clearInterval(interval)
    )

  keepNormalized: (fn) ->
    fn.call(this)
    @doc.rebuildDirty()
    @doc.forceTrailingNewline()

  # applyAttribute: (TandemRange range, String attr, Mixed value) ->
  # applyAttribute: (Number index, Number length, String attr, Mixed value) ->
  applyAttribute: (index, length, attr, value, emitEvent = true) ->
    delta = this.trackDelta( =>
      @selection.preserve( =>
        this.keepNormalized( =>
          @doc.applyAttribute(index, length, attr, value)
        )
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  applyDelta: (delta) ->
    console.assert(delta.startLength == @doc.length, "Trying to apply delta to incorrect doc length", delta, @doc, @doc.root)
    index = 0       # Stores where the last retain end was, so if we see another one, we know to delete
    offset = 0      # Tracks how many characters inserted to correctly offset new text
    oldDelta = @doc.toDelta()
    delta = stripNewlineAttributes(delta)
    cursors = {}
    _.each(delta.deltas, (delta) =>
      if JetDelta.isInsert(delta)
        cursors[delta.attributes['author']] = index + offset + delta.text.length if delta.attributes['author']?
        offset += delta.getLength()
      else if JetDelta.isRetain(delta)
        if delta.start > index
          offset -= (delta.start - index)
        index = delta.end
      else
        console.warn('Unrecognized type in delta', delta)
    )
    _.each(cursors, (index, userId) =>
      this.removeCursor(userId)
    )

    index = offset = 0
    retains = []
    _.each(delta.deltas, (delta) =>
      if JetDelta.isInsert(delta)
        @doc.insertText(index + offset, delta.text)
        retains.push(new JetRetain(index + offset, index + offset + delta.text.length, delta.attributes))
        offset += delta.getLength()
      else if JetDelta.isRetain(delta)
        if delta.start > index
          @doc.deleteText(index + offset, delta.start - index)
          offset -= (delta.start - index)
        retains.push(new JetRetain(delta.start + offset, delta.end + offset, delta.attributes))
        index = delta.end
      else
        console.warn('Unrecognized type in delta', delta)
    )
    # If end of text was deleted
    if delta.endLength < delta.startLength + offset
      @doc.deleteText(delta.endLength, delta.startLength + offset - delta.endLength)
    retainDelta = new JetDelta(delta.endLength, delta.endLength, retains)
    retainDelta.compact()
    _.each(retainDelta.deltas, (delta) =>
      _.each(delta.attributes, (value, attr) =>
        @doc.applyAttribute(delta.start, delta.end - delta.start, attr, value) if value == null
      )
      _.each(delta.attributes, (value, attr) =>
        @doc.applyAttribute(delta.start, delta.end - delta.start, attr, value) if value?
      )
    )
    @doc.forceTrailingNewline()
    this.applyDeltaToCursors(delta)
    _.each(cursors, (index, userId) =>
      this.moveCursor(userId, index)
    )
    newDelta = @doc.toDelta()
    composed = JetSync.compose(oldDelta, delta)
    composed.compact()
    console.assert(_.isEqual(composed, newDelta), oldDelta, delta, composed, newDelta)

  deleteAt: (index, length, emitEvent = true) ->
    delta = this.trackDelta( =>
      @selection.preserve( =>
        this.keepNormalized( =>
          @doc.deleteText(index, length)
        )
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  getAt: (index, length) ->
    # - Returns array of {text: "", attr: {}}
    # 1. Get all nodes in the range
    # 2. For first and last, change the text
    # 3. Return array
    # - Helper to get nodes in given index range
    # - In the case of 0 lenght, text will always be "", but attributes should be properly applied

  getDelta: ->
    return @doc.toDelta()

  getSelection: ->
    return @selection.getRange()

  insertAt: (index, text, emitEvent = true) ->
    delta = this.trackDelta( =>
      @selection.preserve( =>
        this.keepNormalized( =>
          @doc.insertText(index, text)
        )
      )
    , emitEvent)
    this.emit(TandemEditor.events.API_TEXT_CHANGE, delta) if emitEvent

  setSelection: (range) ->
    @selection.setRange(range)

  trackDelta: (fn, track = true) ->
    oldIgnoreDomChange = @ignoreDomChanges
    @ignoreDomChanges = true
    delta = null
    if track
      oldDelta = @doc.toDelta()
      fn()
      newDelta = @doc.toDelta()
      decompose = JetSync.decompose(oldDelta, newDelta)
      compose = JetSync.compose(oldDelta, decompose)
      console.assert(_.isEqual(compose, newDelta), oldDelta, newDelta, decompose, compose)
      delta = stripNewlineAttributes(decompose)
      this.applyDeltaToCursors(delta)
    else
      fn()
    @ignoreDomChanges = oldIgnoreDomChange
    return delta

  update: ->
    delta = this.trackDelta( =>
      @selection.preserve( =>
        Tandem.Document.normalizeHtml(@doc.root)
        lines = @doc.lines.toArray()
        lineNode = @doc.root.firstChild
        _.each(lines, (line, index) =>
          while line.node != lineNode
            if line.node.parentNode == @doc.root
              newLine = @doc.insertLineBefore(lineNode, line)
              lineNode = lineNode.nextSibling
            else
              @doc.removeLine(line)
              return
          @doc.updateLine(line)
          lineNode = lineNode.nextSibling
        )
        while lineNode != null
          newLine = @doc.appendLine(lineNode)
          lineNode = lineNode.nextSibling
      )
      @selection.update(true)
    , true)
    return delta



window.Tandem ||= {}
window.Tandem.Editor = TandemEditor
