require 'spec_helper'

require 'cinch/test'
require 'cinch/plugins/game_bot'
require 'example_plugin'

def get_replies_text(m)
  replies = get_replies(m)
  # If you wanted, you could read all the messages as they come, but that might be a bit much.
  # You'd want to check the messages of user1, user2, and chan as well.
  # replies.each { |x| puts(x.text) }
  replies.map(&:text)
end

class MessageReceiver
  attr_reader :name
  attr_accessor :messages

  def initialize(name)
    @name = name
    @messages = []
  end

  def send(m)
    @messages << m
  end
end

class TestChannel < MessageReceiver
  def voiced
    []
  end
  def voice(_)
  end
  def devoice(_)
  end
  def moderated=(_)
  end
end

RSpec.describe Cinch::Plugins::GameBot do
  include Cinch::Test

  let(:channel1) { '#test' }
  let(:chan) { TestChannel.new(channel1) }
  let(:bogus_channel) { '#bogus' }
  let(:player1) { 'test1' }
  let(:player2) { 'test2' }
  let(:player3) { 'test3' }
  let(:player4) { 'test4' }
  let(:players) { [
    player1,
    player2,
    player3,
    player4,
  ]}

  let(:opts) {{
    channels: [channel1],
    settings: '/dev/null',
    changelog_file: 'my-changes',
    mods: [player1],
  }}
  let(:bot) {
    make_bot(Cinch::Plugins::ExamplePlugin, opts) { |c| c.loggers.first.level = :warn }
  }
  let(:plugin) { bot.plugins.first }

  def msg(text, nick: player1, channel: channel1)
    return make_message(bot, text, nick: nick) unless channel
    make_message(bot, text, nick: nick, channel: channel)
  end
  def authed_msg(text, nick: player1, channel: channel1)
    m = msg(text, nick: nick, channel: channel)
    allow(m.user).to receive(:authed?).and_return(true)
    allow(m.user).to receive(:authname).and_return(nick)
    m
  end

  def join(message)
    expect(message.channel).to receive(:has_user?).with(message.user).and_return(true)
    expect(message.channel).to receive(:voice).with(message.user)
    get_replies(message)
  end

  it 'makes a test bot' do
    expect(bot).to be_a(Cinch::Bot)
  end

  describe '!join' do
    it 'lets a single player join' do
      replies = join(msg('!join', nick: player1)).map(&:text)
      expect(replies).to be == ["#{player1} has joined the game (1/3)"]
    end

    it 'allows join via PM' do
      m = msg("!join #{channel1}", nick: player1, channel: nil)
      expect(plugin).to receive(:Channel).with(channel1).and_return(chan)
      expect(chan).to receive(:has_user?).with(m.user).and_return(true)
      expect(chan).to receive(:voice).with(m.user)

      get_replies(m)

      expect(chan.messages).to be == ["#{player1} has joined the game (1/3)"]
    end

    it 'requires channel argument by PM' do
      m = msg("!join", nick: player1, channel: nil)
      replies = get_replies_text(m)

      expect(replies).to be_all { |r| r =~ /must specify the channel/ }
      expect(replies.size).to be == 1
    end

    it 'requires channel presence' do
      replies = get_replies_text(msg('!join', nick: player1))
      expect(replies).to be == ["#{player1}: You need to be in #{channel1} to join the game."]
    end

    it 'disallows double joins' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      # We need to mess with Cinch::User.new because cinch-test is messing with us.
      # (creating users who are eql? but whose hash are not the same)
      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)
      replies = get_replies_text(msg('!join', nick: player1))
      expect(replies).to be == ["#{player1}: You are already in the #{channel1} game"]
    end

    it 'disallows bogus channel' do
      replies = get_replies_text(msg('!join', nick: player1, channel: bogus_channel))
      expect(replies).to be == ["#{player1}: #{bogus_channel} is not a valid channel to join"]
    end

    it 'disallows joining started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      m = msg('!join', nick: player3)
      expect(m.channel).to receive(:has_user?).with(m.user).and_return(true)
      replies = get_replies_text(m)
      expect(replies).to be == ["#{player3}: Game has already started."]
    end

    it 'disallows double-joining started game' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      # We need to mess with Cinch::User.new because cinch-test is messing with us.
      # (creating users who are eql? but whose hash are not the same)
      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)
      replies = get_replies_text(msg('!join', nick: player1))
      # Empty because of the no reply on join in the same channel rule
      expect(replies).to be_empty
    end

    it 'disallows overflow' do
      players.take(3).each { |p| join(msg('!join', nick: p)) }
      m = msg('!join', nick: player4)
      expect(m.channel).to receive(:has_user?).with(m.user).and_return(true)
      replies = get_replies_text(m)
      expect(replies).to be == [
        "#{player4}: Game is already at 3 players, the maximum supported for Example Game."
      ]
    end
  end

  describe '!leave' do
    it 'no-ops if player is not in game' do
      replies = get_replies(msg('!leave', nick: player1))
      expect(replies).to be_empty
    end

    it 'leaves game' do
      join(msg('!join', nick: player1))
      expect(plugin).to receive(:Channel).with(channel1).and_return(chan)
      get_replies(msg('!leave', nick: player1))
      expect(chan.messages).to be == ["#{player1} has left the game (0/3)"]
    end

    it 'disallows leaving started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!leave', nick: player1))
      expect(replies).to be == ["#{player1}: You cannot leave a game in progress."]
    end
  end

  describe '!start' do
    it 'disallows bystander start' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      replies = get_replies_text(msg('!start', nick: player3))
      expect(replies).to be == ["#{player3}: You are not in the game."]
    end

    it 'allows start' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies_text(msg('!start'))
      # What to test here? This just tests that we have no crash. !status and !who are testing a bit.
    end

    it 'does not start the game if the game fails to start somehow' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      replies = get_replies(msg('!start fail'))
      expect(replies).to be_empty
      # Best way to determine that the game hasn't started?
      replies = get_replies_text(msg('!status'))
      expect(replies).to be_all { |r| r.include?('is forming') }
      expect(replies).to_not be_any { |r| r.include?('started') }
    end

    it 'disallows start with too few players' do
      join(msg('!join', nick: player1))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!start', nick: player1))
      expect(replies).to be == ["#{player1}: Need at least 2 to start a game of Example Game."]
    end
  end

  describe '!who' do
    it 'says no players in game' do
      replies = get_replies_text(msg('!who', nick: player1))
      expect(replies).to be == ['No one has joined the game yet.']
    end

    it 'names players in unstarted game' do
      join(msg('!join', nick: player1))
      replies = get_replies_text(msg('!who', nick: player1)).map { |t| t.gsub(/\W/, '') }
      expect(replies).to be == [player1]
    end

    it 'names players in started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!who', nick: player1)).map { |t| t.gsub(/[^a-z0-9 ]/, '') }
      expect(replies).to be == ["#{player1} #{player2}"]
    end

    it 'names players in unstarted game by PM if requestor is in one' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      # We need to mess with Cinch::User.new because cinch-test is messing with us.
      # (creating users who are eql? but whose hash are not the same)
      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)

      replies = get_replies_text(msg('!who', nick: player1, channel: nil)).map { |t| t.gsub(/[^a-z0-9 ]/, '') }

      expect(replies).to be_all { |r| r == player1 }
      expect(replies.size).to be == 1
    end

    it 'asks for a channel if requestor does not specify one by PM' do
      join(msg('!join', nick: player2))

      replies = get_replies_text(msg('!who', nick: player1, channel: nil))

      expect(replies).to be_all { |r| r.include?('must specify the channel') }
      expect(replies.size).to be == 1
    end

    it 'names players in unstarted game by PM if requestor explicitly specifies' do
      join(msg('!join', nick: player2))

      replies = get_replies_text(msg("!who #{channel1}", nick: player1, channel: nil)).map { |t| t.gsub(/[^a-z0-9 ]/, '') }

      expect(replies).to be_all { |r| r == player2 }
      expect(replies.size).to be == 1
    end
  end

  describe '!status' do
    it 'says no players in game' do
      replies = get_replies_text(msg('!status', nick: player1))
      expect(replies).to be == ['No game of Example Game in progress. Join and start one!']
    end

    it 'names players in unstarted game' do
      join(msg('!join', nick: player1))
      replies = get_replies_text(msg('!status', nick: player1))
      expect(replies).to be == ["A game of Example Game is forming. 1 players have joined: #{player1}"]
    end

    it 'names players in started game' do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      replies = get_replies_text(msg('!status', nick: player1))
      expect(replies).to be == ["Game started with players test1, test2"]
    end

    it 'names players in unstarted game by PM if requestor is in one' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      # We need to mess with Cinch::User.new because cinch-test is messing with us.
      # (creating users who are eql? but whose hash are not the same)
      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)

      replies = get_replies_text(msg('!status', nick: player1, channel: nil))

      expect(replies).to be_all { |r| r.include?('is forming') }
      expect(replies.size).to be == 1
    end
  end

  describe '#start_new_game' do
    it 'allows the players to join new games' do
      first_message = msg('!join', nick: player1)
      join(first_message)
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      allow(plugin).to receive(:Channel).with(channel1).and_return(chan)
      expect(get_replies_text(msg('!win_game'))).to be == ['CONGRATULATIONS, YOU WIN!']

      expect(Cinch::User).to receive(:new).with(player1, anything).and_return(first_message.user)
      replies = join(msg('!join', nick: player1)).map(&:text)
      expect(replies).to be == ["#{player1} has joined the game (1/3)"]
    end
  end

  describe '!intro' do
    it 'responds' do
      replies = get_replies_text(msg('!intro'))
      expect(replies).to_not be_empty
    end
  end

  describe '!invite' do
    it 'sends invites' do
      expect(plugin).to receive(:load_settings).and_return('subscribers' => ['joe'])
      joe = instance_double(Cinch::User)
      expect(plugin).to receive(:User).with('joe').and_return(joe)
      expect(joe).to receive(:refresh)
      expect(joe).to receive(:online?).and_return(true)
      expect(joe).to receive(:send).with(/game.*is gathering/)

      replies = get_replies_text(msg('!invite'))
      expect(replies).to be == ['Invitation has been sent.']
    end

    it 'disallows spamming' do
      get_replies_text(msg('!invite'))
      expect(plugin).not_to receive(:load_settings)
      replies = get_replies_text(msg('!invite', nick: player2))
      expect(replies).to be == ["#{player2}: An invitation cannot be sent out again so soon."]
    end
  end

  describe '!subscribe' do
    it 'requires registration' do
      m = msg('!subscribe')
      expect(m.user).to receive(:authed?).and_return(false)
      expect(plugin).not_to receive(:save_settings)

      replies = get_replies_text(m)

      expect(replies).to be_any { |r| r.include?('identified') }
    end

    it 'subscribes' do
      expect(plugin).to receive(:save_settings).with('subscribers' => [player1])

      replies = get_replies_text(authed_msg('!subscribe', nick: player1))

      expect(replies).to be_any { |r| r.include?('been subscribed') }
    end

    it 'does nothing if already subscribed' do
      expect(plugin).to receive(:load_settings).and_return('subscribers' => [player1])

      replies = get_replies_text(authed_msg('!subscribe', nick: player1))

      expect(replies).to be_any { |r| r.include?('already subscribed') }
    end
  end

  describe '!unsubscribe' do
    it 'requires registration' do
      m = msg('!unsubscribe')
      expect(m.user).to receive(:authed?).and_return(false)
      allow(plugin).to receive(:load_settings).and_return('subscribers' => [player1])
      expect(plugin).not_to receive(:save_settings)

      replies = get_replies_text(m)

      expect(replies).to be_any { |r| r.include?('identified') }
    end

    it 'unsubscribes' do
      expect(plugin).to receive(:load_settings).and_return('subscribers' => [player1])
      expect(plugin).to receive(:save_settings).with('subscribers' => [])

      replies = get_replies_text(authed_msg('!unsubscribe', nick: player1))

      expect(replies).to be_any { |r| r.include?('been unsubscribed') }
    end

    it 'does nothing if not already subscribed' do
      expect(plugin).not_to receive(:save_settings)

      replies = get_replies_text(authed_msg('!unsubscribe', nick: player1))

      expect(replies).to be_any { |r| r.include?('not subscribed') }
    end
  end

  describe '!changelog' do
    before(:each) do
      # settings file, not related to this test
      allow(File).to receive(:exist?).with('/dev/null').and_call_original
      allow(YAML).to receive(:load_file).with('/dev/null').and_call_original

      expect(File).to receive(:exist?).with('my-changes').and_return(true)
      expect(YAML).to receive(:load_file).with('my-changes').and_return([{
        'date' => 'date1',
        'changes' => ['change1', 'change2'],
      }])
    end

    it 'responds with no number' do
      replies = get_replies_text(msg('!changelog'))
      expect(replies).to be == ['1 - date1 - 2 changes']
    end

    it 'responds with number' do
      replies = get_replies_text(msg('!changelog 1'))
      expect(replies).to be == [
        'Changes for date1:',
        '- change1',
        '- change2',
      ]
    end

    it 'responds with invalid number' do
      replies = get_replies_text(msg('!changelog 2'))
      expect(replies).to be == ['No changes on page 2!']
    end
  end

  describe '!reset' do
    before(:each) do
      join(msg('!join', nick: player1))
      join(msg('!join', nick: player2))
      get_replies(msg('!start'))
      allow(plugin).to receive(:Channel).with(channel1).and_return(chan)
    end

    it 'does nothing for non-mods' do
      expect(get_replies(authed_msg("!reset", nick: player2))).to be_empty
      expect(chan.messages).to be_empty
    end

    it 'allows mod to reset a game' do
      expect(get_replies(authed_msg("!reset", nick: player1))).to be_empty
      expect(chan.messages).to include('plugin-specific reset message')
      expect(chan.messages).to include('The game has been reset.')
    end
  end

  describe '!replace' do
    before(:each) do
      allow(plugin).to receive(:Channel).with(channel1).and_return(chan)
    end

    it 'does nothing for non-mods' do
      first_message = msg('!join', nick: player2)
      join(first_message)
      allow(plugin).to receive(:User).with(player2).and_return(first_message.user)
      allow(plugin).to receive(:User).with(player3).and_call_original
      expect(get_replies(authed_msg("!replace #{player2} #{player3}", nick: player4))).to be_empty
      expect(chan.messages).to be_empty
    end

    it 'lets mod replace a player in a waiting room' do
      first_message = msg('!join', nick: player2)
      join(first_message)
      expect(plugin).to receive(:User).with(player2).and_return(first_message.user)
      allow(plugin).to receive(:User).with(player3).and_call_original
      get_replies(authed_msg("!replace #{player2} #{player3}", nick: player1))
      expect(chan.messages).to be == ["#{player2} has been replaced with #{player3}"]
    end

    it 'lets mod replace a player in a started game' do
      first_message = msg('!join', nick: player2)
      join(first_message)
      join(msg('!join', nick: player1))
      get_replies(msg('!start'))
      expect(plugin).to receive(:User).with(player2).and_return(first_message.user)
      allow(plugin).to receive(:User).with(player3).and_call_original
      get_replies(authed_msg("!replace #{player2} #{player3}", nick: player1))
      expect(chan.messages).to include("plugin-specific replace message: #{player2} -> #{player3}")
      expect(chan.messages).to include("#{player2} has been replaced with #{player3}")
    end

    it 'fails if game denies the replacement' do
      first_message = msg('!join', nick: player2)
      join(first_message)
      join(msg('!join', nick: player1))
      get_replies(msg('!start noreplace'))
      expect(plugin).to receive(:User).with(player2).and_return(first_message.user)
      allow(plugin).to receive(:User).with(player3).and_call_original
      get_replies(authed_msg("!replace #{player2} #{player3}", nick: player1))
      expect(chan.messages).to be_empty
    end

    it 'fails if replacer is already in a game' do
      first_message2 = msg('!join', nick: player2)
      join(first_message2)
      first_message3 = msg('!join', nick: player3)
      join(first_message3)
      expect(plugin).to receive(:User).with(player2).and_return(first_message2.user)
      expect(plugin).to receive(:User).with(player3).and_return(first_message3.user)
      replies = get_replies_text(authed_msg("!replace #{player2} #{player3}", nick: player1))
      expect(replies).to be == ["#{player3} is already in the #{channel1} game."]
      expect(chan.messages).to be_empty
    end
  end

  describe '!kick' do
    before(:each) do
      allow(plugin).to receive(:Channel).with(channel1).and_return(chan)
    end

    it 'does nothing for non-mods' do
      first_message = msg('!join', nick: player2)
      join(first_message)
      allow(plugin).to receive(:User).with(player2).and_return(first_message.user)
      expect(get_replies(authed_msg("!kick #{player2}", nick: player3))).to be_empty
      expect(chan.messages).to be_empty
    end

    it 'lets mod kick a player' do
      first_message = msg('!join', nick: player2)
      join(first_message)
      expect(plugin).to receive(:User).with(player2).and_return(first_message.user)
      get_replies(authed_msg("!kick #{player2}", nick: player1))
      expect(chan.messages).to be == ["#{player2} has left the game (0/3)"]
    end

    it 'disallows kicking from started games' do
      join(msg('!join', nick: player1))
      first_message = msg('!join', nick: player2)
      join(first_message)
      get_replies(msg('!start'))
      expect(plugin).to receive(:User).with(player2).and_return(first_message.user)
      replies = get_replies_text(authed_msg("!kick #{player2}", nick: player1))
      expect(replies).to be == ["You can't kick someone while a game is in progress."]
      expect(chan.messages).to be_empty
    end

    it 'shows error if target is not in a game' do
      replies = get_replies_text(authed_msg("!kick #{player2}", nick: player1))
      expect(replies).to be == ["#{player2} is not in a game"]
      expect(chan.messages).to be_empty
    end
  end

  describe '!room' do
    it 'does not let non-mods change' do
      m = authed_msg('!room silent', nick: player2)
      expect(m.channel).not_to receive(:moderated=)

      get_replies(m)
    end

    it 'lets mods change to silent' do
      m = authed_msg('!room silent', nick: player1)
      expect(m.channel).to receive(:moderated=).with(true)

      get_replies(m)
    end

    it 'lets mods change to vocal' do
      m = authed_msg('!room vocal', nick: player1)
      expect(m.channel).to receive(:moderated=).with(false)

      get_replies(m)
    end
  end

  describe '!notice' do
    before(:each) { Cinch.pm_users.clear }

    it 'it uses NOTICE if turned on' do
      Cinch.pm_users.add(player1)
      expect(plugin).to receive(:save_settings).with('pm_users' => [])

      replies = get_replies_text(msg('!notice on', nick: player1))

      expect(replies).to be_all { |r| r.include?('NOTICE') }
      expect(Cinch.pm_users).not_to include(player1)
    end

    it 'it uses PRIVMSG if turned off' do
      expect(plugin).to receive(:save_settings).with('pm_users' => [player1])

      replies = get_replies_text(msg('!notice off', nick: player1))

      expect(replies).to be_all { |r| r.include?('PRIVMSG') }
      expect(Cinch.pm_users).to include(player1)
    end

    it 'lets mods list' do
      get_replies(msg('!notice off', nick: player2))

      replies = get_replies_text(authed_msg('!notice list', nick: player1))

      expect(replies).to be_all { |r| r.include?('PRIVMSG users') }
      expect(replies).to be_all { |r| r.include?(player2) }
    end

    it 'does not let non-mods list' do
      get_replies(msg('!notice off', nick: player2))

      replies = get_replies_text(authed_msg('!notice list', nick: player2))

      expect(replies).to_not be_any { |r| r.include?('PRIVMSG users') }
    end

    it 'lets mods act on others' do
      expect(plugin).to receive(:save_settings).with('pm_users' => [player2])

      get_replies(authed_msg("!notice off #{player2}", nick: player1))

      expect(Cinch.pm_users).not_to include(player1)
      expect(Cinch.pm_users).to include(player2)
    end

    it 'only lets non-mods act on self' do
      # player2, non-mod, attempting to act on player1.
      # Will just act on self instead.
      expect(plugin).to receive(:save_settings).with('pm_users' => [player2])

      get_replies(authed_msg("!notice off #{player1}", nick: player2))

      expect(Cinch.pm_users).not_to include(player1)
      expect(Cinch.pm_users).to include(player2)
    end
  end
end
