helpers = require './helpers'
parser = require './parser'
parser_state = require './parser_state'

implicit = helpers.implicit
resolve = helpers.resolve

ParserState = parser_state.ParserState
Match = parser_state.Match
NoMatch = parser_state.NoMatch

#
# functions that transform or combine other Parsers.
#

# a parser that can fail to match, and returns a default response if not
# present (usually the empty string).
optional = (p, defaultValue="") ->
  p = implicit(p)
  message = -> "optional(#{resolve(p).message()})"
  new parser.Parser message, (state, cont) ->
    p = resolve(p)
    p.parse state, (rv) ->
      if rv.ok or rv.abort then return cont(rv)
      cont(new Match(state, defaultValue, rv.commit, message))

# check that this parser matches, but don't advance the string. (perl calls
# this a zero-width lookahead.)
check = (p) ->
  p = implicit(p)
  message = -> resolve(p).message()
  new parser.Parser message, (state, cont) ->
    p = resolve(p)
    p.parse state, (rv) ->
      if not rv.ok then return cont(rv)
      cont(new Match(state, rv.match, rv.commit, message))

# if the parser matches up to here, refuse to backtrack to previous
# alternatives.
commit = (p) ->
  p = implicit(p)
  new parser.Parser (-> resolve(p).message()), (state, cont) ->
    p = resolve(p)
    p.parse state, (rv) ->
      if not rv.ok then return cont(rv)
      rv.commit = true
      state.debug -> "commit!"
      cont(rv)

# succeed (with an empty match) if the parser failed; otherwise fail.
not_ = (p) ->
  p = implicit(p)
  message = -> "not(#{resolve(p).message()})"
  new parser.Parser message, (state, cont) ->
    p = resolve(p)
    p.parse state, (rv) =>
      if rv.ok then @fail(state, cont) else cont(new Match(state, "", rv.commit, message))

# throw away the match.
drop = (p) -> implicit(p).onMatch (x) -> null

# chain together p1 & p2 such that if p1 matches, p2 is executed. if both
# match, 'combiner' is called with the two matched objects, to create a
# single match result.
chain = (p1, p2, combiner) ->
  message = -> "(#{resolve(p1).message()} then #{resolve(p2).message()})"
  new parser.Parser message, (state, cont) ->
    p1 = resolve(p1)
    p1.parse state, (rv1) ->
      if not rv1.ok then return cont(rv1)
      p2 = resolve(p2)
      p2.parse rv1.state, (rv2) ->
        if not rv2.ok
          # no backtracking if the left match was commit()'d.
          if rv1.commit then rv2.abort = true
          return cont(rv2)
        cont(new Match(rv2.state, combiner(rv1.match, rv2.match), rv2.commit or rv1.commit, message))

# chain together a sequence of parsers. if they all match, the match result
# will contain an array of all the results that weren't null.
seq = (parsers...) ->
  parsers = (implicit(p) for p in parsers)
  if parsers.length == 1 then return parsers[0]
  message = -> "(" + (resolve(p).message() for p in parsers).join(" then ") + ")"
  p0 = parsers.shift()
  p1 = parsers.shift()
  p = chain p0, p1, (rv1, rv2) -> 
    sum = []
    if rv1? then sum.push rv1
    if rv2? then sum.push rv2
    sum
  parsers.unshift p
  combiner = (sum, x) ->
    if x?
      sum = sum[...]
      sum.push x
    sum
  rv = parsers.reduce (p1, p2) -> chain(p1, p2, combiner)
  new parser.Parser message, (state, cont) ->
    rv.parse state, cont

# chain together a sequence of parsers. before each parser is checked, the
# 'ignore' parser is optionally matched and thrown away. this is typicially
# used for discarding whitespace in lexical parsing.
seqIgnore = (ignore, parsers...) ->
  parsers = (implicit(p) for p in parsers)
  message = -> "(" + (resolve(p).message() for p in parsers).join(" then ") + ")"
  newseq = []
  for p in parsers
    newseq.push optional(ignore).drop()
    newseq.push p
  rv = seq(newseq...)
  new parser.Parser message, (state, cont) ->
    rv.parse state, cont

# try each of these parsers, in order (starting from the same position),
# looking for the first match.
alt = (parsers...) ->
  parsers = (implicit(p) for p in parsers)
  message = -> "(" + (resolve(p).message() for p in parsers).join(" or ") + ")"
  new parser.Parser message, (state, cont) ->
    parsers = (resolve(p) for p in parsers)
    state.debug -> [
      "alt: start @ #{state}"
      for p in parsers then "- #{p}"
    ]
    aborting = false
    for p in parsers then do (p) ->
      state.addJob (=> "alt: #{state}, #{p}"), ->
        if aborting then return
        state.debug -> "alt: next try: #{p} at #{state}"
        p.parse state, (rv) ->
          if rv.abort then aborting = true
          return cont(rv)

# from 'min' to 'max' (inclusive) repetitions of a parser, returned as an
# array. 'max' may be omitted to mean infinity.
repeat = (p, minCount=0, maxCount=null) ->
  p = implicit(p)
  if maxCount?
    countMessage = "{#{minCount}, #{maxCount}}"
  else
    countMessage = "{#{minCount}+}"
    maxCount = Math.pow(2, 31)
  message = -> "(" + resolve(p).message() + ")#{countMessage}"
  new parser.Parser message, (state, cont) ->
    p = resolve(p)
    origState = state
    count = 0
    nextCont = (rv, list=[], lastState=origState) =>
      if not rv.ok
        if count >= minCount
          # intentionally use the "last good state" from our repeating parser.
          return cont(new Match(lastState, list, rv.commit, message))
        return @fail(origState, cont)
      count += 1
      if rv.match? then list.push rv.match
      if count < maxCount
        # if a parser matches nothing, we could go on forever...
        if rv.state.pos == origState.pos then throw new Error("Repeating parser isn't making progress: #{rv.state.pos}=#{origState.pos} #{p}")
        rv.state.addJob (=> "repeat: #{state}, #{message()}"), ->
          p.parse rv.state, (x) -> nextCont(x, list[...], rv.state)
      else
        cont(new Match(rv.state, list, rv.commit, message))
    p.parse origState, nextCont

# like 'repeat', but each element may be optionally preceded by 'ignore',
# which will be thrown away. this is usually used to remove leading
# whitespace.
repeatIgnore = (ignore, p, minCount=0, maxCount=null) ->
  p2 = seq(optional(ignore).drop(), p).onMatch (x) -> x[0]
  repeat(p2, minCount, maxCount)

# like 'repeat', but the repeated elements are separated by 'separator',
# which is ignored.
repeatSeparated = (p, separator="", minCount=1, maxCount=null) ->
  p2 = seq(drop(separator), p).onMatch (x) -> x[0]
  seq(p, repeat(p2, minCount - 1, if maxCount? then maxCount - 1 else maxCount)).onMatch (x) ->
    [ x[0] ].concat(x[1])

# convenience method for reducing the result of 'repeatSeparated', optionally
# keeping the separator results. if 'accumulator' exists, it will transform
# the initial result into an accumulator. if 'reducer' exists, it will be
# used to progressively attach separators and new results.
reduce = (p, separator="", accumulator=null, reducer=null, minCount=1, maxCount=null) ->
  if not accumulator? then accumulator = (x) -> [ x ]
  if not reducer? then reducer = (sum, sep, x) -> sum.push(x)
  seq(p, repeat(seq(separator, p), minCount - 1, if maxCount? then maxCount - 1 else maxCount)).onMatch (x) ->
    [ accumulator(x[0]) ].concat(x[1]).reduce (sum, item) -> reducer(sum, item[0], item[1])


exports.optional = optional
exports.check = check
exports.commit = commit
exports.not_ = not_
exports.drop = drop
exports.chain = chain
exports.seq = seq
exports.seqIgnore = seqIgnore
exports.alt = alt
exports.repeat = repeat
exports.repeatIgnore = repeatIgnore
exports.repeatSeparated = repeatSeparated
exports.reduce = reduce
