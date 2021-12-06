ws = require 'ws'
url = require 'url'

snake = require './entities/snake'
food = require './entities/food'

messages = require './messages'

logger = require './utils/logger'
message = require './utils/message'
math = require './utils/math'

module.exports =
class Server
  ###
  Section: Properties
  ###
  logger: new logger(this)
  server: null
  counter: 0
  clients: []
  time: new Date
  tick: 0

  foods: []

  ###
  Section: Construction
  ###
  constructor: (@port) ->
    global.Server = this

  ###
  Section: Public
  ###
  bind: ->
    @server = new ws.Server {@port, path: '/slither'}, =>
      @logger.log @logger.level.INFO, "Listening for connections"

      # Generate start food
      @generateFood(global.Application.config['start-food'])

    @server.on 'connection', @handleConnection.bind(this)
    @server.on 'error', @handleError.bind(this)

  ###
  Section: Private
  ###
  handleConnection: (conn) ->
    conn.binaryType = 'arraybuffer'

    # Limit connections
    if @clients.length >= global.Application.config['max-connections']
      conn.close()
      return

    # Check connection origin
    params = url.parse(conn.upgradeReq.url, true).query
    origin = conn.upgradeReq.headers.origin
    unless global.Application.config.origins.indexOf(origin) > -1
      conn.close()
      return

    conn.id = ++@counter
    conn.remoteAddress = conn._socket.remoteAddress

    # Push to clients
    @clients[conn.id] = conn

    # Bind socket connection methods
    close = (id) =>
      @logger.log @logger.level.DEBUG, 'Connection closed.'

      conn.send = -> return

      # This avoid the snake still moving when the client close the socket
      # TODO: Check if this is the right behavior
      # clearInterval(conn.snake.update)

      delete @clients[id]

    conn.on 'message', @handleMessage.bind(this, conn)
    conn.on 'error', close.bind(this, conn.id)
    conn.on 'close', close.bind(this, conn.id)

    @send conn.id, messages.initial.buffer

  handleMessage: (conn, data) ->
    return if data.length == 0

    if data.length is 1
      value = message.readInt8 0, data

      if value <= 250
        console.log 'Snake going to', value

        radians = (value * 1.44) * (Math.PI / 180)
        degrees = 0
        speed = 1

        x = Math.cos(radians) + 1 * speed
        y = Math.sin(radians) + 1 * speed

        conn.snake.direction.x = x * 125
        conn.snake.direction.y = y * 125

        conn.snake.direction.angle = value * 1.44

        # TODO: Fix crash due to bad calculations
        # @broadcast messages.direction.build(conn.snake.id, conn.snake.direction)
      else if value is 253
        console.log 'Snake in speed mode -', value
      else if value is 254
        console.log 'Snake in normal mode -', value
      else if value is 251        
        @send conn.id, messages.pong.buffer
    else
      ###
      firstByte:
        115 - 's'
      ###
      firstByte = message.readInt8 0, data
      secondByte = message.readInt8 1, data

      # Create snake
      if firstByte is 115 and secondByte is 5
        # TODO: Maybe we need to check if the skin exists?
        skin = message.readInt8 2, data
        name = message.readString 3, data, data.byteLength

        # Create the snake
        conn.snake = new snake(conn.id, name, x: 28907.6 * 5, y: 21137.4 * 5, skin)
        @broadcast messages.snake.build(conn.snake)

        @logger.log @logger.level.DEBUG, "A new snake called #{conn.snake.name} was connected!"

        # Spawn current playing snakes
        @spawnSnakes(conn.id)

        # Update snake position each 120ms
        conn.snake.update = setInterval(() =>
          conn.snake.body.x += Math.cos((Math.PI / 180) * conn.snake.direction.angle) * 170
          conn.snake.body.y += Math.sin((Math.PI / 180) * conn.snake.direction.angle) * 170

          @broadcast messages.movement.build(conn.snake.id, conn.snake.direction.x, conn.snake.direction.y)
        , 120)
        
        # Send spawned food
        # TODO: Only send the food inside the current sector
        @send conn.id, messages.food.build(@foods)

        # Update highscore, leaderboard and minimap
        # TODO: Move this to a global tick method
        @send conn.id, messages.leaderboard.build([conn], 1, [conn])
        @send conn.id, messages.highscore.build('iiegor', 'A high score message')
        @send conn.id, messages.minimap.build(@foods)
      else if firstByte is 109
        console.log '->', secondByte
      else
        @logger.log @logger.level.ERROR, "Unhandled message #{String.fromCharCode(firstByte)}", null

  handleError: (e) ->
    switch e.code
      when 'EADDRINUSE'
        @logger.log @logger.level.ERROR, 'The address is already in use, change the port number', e
      else
        @logger.log @logger.level.ERROR, e.message, e

  generateFood: (amount) ->
    i = 0
    while i < amount
      x = math.randomInt(0, 65535)
      y = math.randomInt(0, 65535)
      id = x * global.Application.config['map-size'] * 3 + y
      color = math.randomInt(0, global.Application.config['food-colors'])
      size = math.randomInt(global.Application.config['food-size'][0], global.Application.config['food-size'][1])

      @foods.push(new food(id, x, y, size, color))

      i++

  spawnSnakes: (id) ->
    @clients.forEach (client) =>
      @send(id, messages.snake.build(client.snake)) if client.id isnt id

  spawnFoodChunks: (id, amount) ->
    for chunk in math.chunk(@foods, amount)
      @send id, messages.food.build(chunk)

  send: (id, data) ->
    @clients[id].send data, {binary: true}

  broadcast: (data) ->
    for client in @clients
      client?.send data, {binary: true}

  close: ->
    @server.close()
