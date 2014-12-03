fibrous = require 'fibrous'
should = require 'should'
logger = require('log4js').getLogger('CHAT')

module.exports = class ChatService

  constructor: (@ModelFactory) ->

  newSocket: (socket, username)->
    socket.username = username
    socket.join "user-#{ username }"

  directMessage: fibrous (io, from, to, message)->
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
    message._id = @ModelFactory.objectId()
    message.sender = from
    conversation.history.push message

    ## async, no need to wait
    conversation.save()

    message.conversationId = conversation._id

    ## we will signal immediately to the destination about this message
    io.to("user-#{ to }").emit('incoming message', message)

