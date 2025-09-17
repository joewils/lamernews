#!/usr/bin/env ruby

# Migration script for PBKDF2 to bcrypt conversion
# This script provides utilities for administrators to manage the password migration

require_relative 'app_config'
require 'redis'

puts "=== Lamer News Password Migration Script ==="
puts "Migration from PBKDF2 to bcrypt"
puts

# Connect to Redis
$r = Redis.new(:url => RedisURL)

def count_users_by_hash_type
  users = []
  user_count = $r.get("users.count").to_i
  
  bcrypt_users = 0
  legacy_users = 0
  
  (1..user_count).each do |id|
    user = $r.hgetall("user:#{id}")
    next if user.empty?
    
    if user['password'] && user['password'].start_with?('$2')
      bcrypt_users += 1
    else
      legacy_users += 1
    end
  end
  
  puts "User password status:"
  puts "- Users with bcrypt passwords: #{bcrypt_users}"
  puts "- Users with legacy PBKDF2 passwords: #{legacy_users}"
  puts "- Total users: #{bcrypt_users + legacy_users}"
  puts
  
  if legacy_users > 0
    puts "⚠️  #{legacy_users} users need to reset their passwords to log in."
    puts "   They will need to use the password reset feature."
  else
    puts "✅ All users have been migrated to bcrypt!"
  end
  
  puts
end

def list_legacy_users
  users = []
  user_count = $r.get("users.count").to_i
  
  puts "Legacy users who need password resets:"
  puts "Username\t\tEmail\t\t\tLast Seen"
  puts "=" * 60
  
  (1..user_count).each do |id|
    user = $r.hgetall("user:#{id}")
    next if user.empty?
    
    unless user['password'] && user['password'].start_with?('$2')
      email = user['email'].empty? ? "(no email)" : user['email']
      last_seen = user['atime'] ? Time.at(user['atime'].to_i) : "unknown"
      puts "#{user['username'].ljust(16)}\t#{email.ljust(20)}\t#{last_seen}"
    end
  end
  puts
end

def send_migration_notice
  puts "Email notification system not implemented in this version."
  puts "Consider manually notifying users about the password reset requirement."
  puts "You can add this to your site's announcement system or send individual emails."
  puts
end

puts "What would you like to do?"
puts "1. Check migration status (count users by password type)"
puts "2. List users who need password resets"  
puts "3. Show migration notice text"
puts "4. Exit"
print "Choice (1-4): "

choice = gets.chomp

case choice
when "1"
  count_users_by_hash_type
when "2"
  list_legacy_users
when "3"
  puts File.read('migration_notice.md')
when "4"
  puts "Exiting..."
else
  puts "Invalid choice. Exiting..."
end