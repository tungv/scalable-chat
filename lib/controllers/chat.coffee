fibrous = require 'fibrous'
should = require 'should'
logger = require('log4js').getLogger('CHAT')

logError = (err)-> logger.warn err if err

## maximum time amount for receiver to mark messages as delivery
## after this timeout, message will be stored in mongo
DELIVERY_TIMEOUT = 500

module.exports = class ChatService

  constructor: (@ModelFactory) ->
    @queue = {}

  newSocket: fibrous (socket, username, token)->
    return socket.disconnect() unless 'string' is typeof username
    return socket.disconnect() unless token?.length

    auth = @ModelFactory.models.authentication_token.sync.findOne {
      CustomerId: username
      AuthenticationKey: token
    }

    unless auth
      logger.warn 'invalid user/token: %s %s',username.bold.cyan, token.bold.cyan
      return socket.disconnect()



    ## preload public key of this user for encryption
    socket.publicKey = @ModelFactory.models.customer.sync.findById(username)?.PublicKey

    unless socket.publicKey
      logger.warn '%s has no public key', username.bold.cyan

    logger.debug '%s signed in with token=%s', username.bold.cyan, token.bold.cyan
    socket.username = username
    socket.join "user-#{ username }"

    @pushNotification socket, username, logError

  isSignedIn: (socket)->
    'string' is typeof socket.username

  pushNotification: fibrous (socket, username)->
    Conversation = @ModelFactory.models.conversation

    ## get all conversations that involves this user and has undelivered msg
    unreadConversations = Conversation.sync.find({
      participants: username
#      undelivered_count: $gte: 1
    })

    ## filter out those are only new for the other party and sent undelivered msg to this user
    unreadConversations.forEach (conv)->
      newMessages = conv.newMessageFor username
      undeliveredMessages = conv.undeliveredOf username

      undeliveredMessages = undeliveredMessages.map (msg)->
        msg.client_fingerprint

      socket.emit 'incoming message', conv._id, newMessages if newMessages.length
      socket.emit 'undelivered message', conv._id, undeliveredMessages


  directMessage: fibrous (io, socket, from, to, message)->
    unless from and to
      throw new Error 'Lacking from or to'

    Conversation = @ModelFactory.models.conversation

    ## find the conversation between these 2
    conversation = Conversation.sync.findOne {
      participants:
        $all: [from, to]
    }

    ## check if conversation is read-only
    if conversation and conversation.readOnly
      throw new {
      code: 'READONLY'
      name: 'MSG_NOT_SENT'
      message: 'This conversation is read-only'
      }

    ## create a new one and save if no conversation found (they haven't chatted)
    unless conversation
      conversation = new Conversation {
        participants: [from, to]
      }

      conversation.sync.save()

    ## now, participants are allow to send message to each other
    message.sender = from
    id = message._id = @ModelFactory.objectId()

    @queue[id] = message

    setTimeout =>
      if @queue[id]
        ## async, no need to wait
        conversation.pushMessage message, (err) =>
          if err
            logger.error "Cannot save message %s in conversation %s", message._id, conversation._id
            return

          delete @queue[id]

    , DELIVERY_TIMEOUT



    socket.emit "outgoing message sent", conversation._id, message.client_fingerprint

    ## we will signal immediately to the destination about this message
    io.to("user-#{ to }").emit('incoming message', conversation._id, message)

    return {conversation, message}

  markDelivered: fibrous (io, socket, conversationId, messageId) ->
    Conversation = @ModelFactory.models.conversation
    conv = Conversation.sync.findById conversationId

    return unless conv
    ## get message from queue, if not there, check history
    message = @queue[messageId] or conv.history.id messageId

    ## remove from queue so message won't be stored to mongo
    delete @queue[messageId]

    conv.markDelivered messageId, ->

    io.to("user-#{ message.sender }").emit('outgoing message delivered', conversationId, message.client_fingerprint)

  typing: fibrous (io, socket, conversationId, username, participants, isTyping)->

    participants.forEach (other)->
      io.to("user-#{ other }").emit('other is typing', conversationId, username, isTyping)
