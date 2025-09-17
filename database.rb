# SQLite Database Layer for Lamer News
# This module provides database connection and helper methods

require 'sqlite3'
require 'json'
require 'securerandom'

module Database
  
  class << self
    attr_accessor :db_path, :connection
    
    def setup(path = 'data/lamernews.db')
      @db_path = path
      @connection = SQLite3::Database.new(@db_path)
      @connection.results_as_hash = true
      
      # Enable foreign key constraints
      @connection.execute("PRAGMA foreign_keys = ON")
      
      # Performance optimizations
      @connection.execute("PRAGMA synchronous = NORMAL")
      @connection.execute("PRAGMA cache_size = 10000")
      @connection.execute("PRAGMA temp_store = MEMORY")
      
      # Cleanup expired items on connection (only if tables exist)
      cleanup_expired_items_if_exist
      
      @connection
    end
    
    def connection
      @connection || setup
    end
    
    def execute(*args)
      connection.execute(*args)
    end
    
    def get_first_row(*args)
      connection.get_first_row(*args)
    end
    
    def get_first_value(*args)
      connection.get_first_value(*args)
    end
    
    def transaction
      connection.transaction do
        yield connection
      end
    end
    
    def last_insert_row_id
      connection.last_insert_row_id
    end
    
    # Counter methods (replaces Redis INCR operations)
    def increment_counter(name, by = 1)
      execute(<<-SQL, [name, by])
        INSERT INTO counters (name, value) VALUES (?, ?)
        ON CONFLICT(name) DO UPDATE SET value = value + excluded.value
      SQL
      
      get_first_value("SELECT value FROM counters WHERE name = ?", name)
    end
    
    def get_counter(name)
      get_first_value("SELECT value FROM counters WHERE name = ?", name) || 0
    end
    
    def set_counter(name, value)
      execute(<<-SQL, [name, value])
        INSERT INTO counters (name, value) VALUES (?, ?)
        ON CONFLICT(name) DO UPDATE SET value = excluded.value
      SQL
    end
    
    # Rate limiting methods (replaces Redis TTL keys)
    def rate_limit_check(key)
      cleanup_expired_rate_limits
      
      result = get_first_value(<<-SQL, [key, Time.now.to_i])
        SELECT expires_at FROM rate_limits 
        WHERE key_name = ? AND expires_at > ?
      SQL
      
      !result.nil?
    end
    
    def rate_limit_set(key, expires_in_seconds)
      expires_at = Time.now.to_i + expires_in_seconds
      
      execute(<<-SQL, [key, expires_at])
        INSERT OR REPLACE INTO rate_limits (key_name, expires_at)
        VALUES (?, ?)
      SQL
    end
    
    def rate_limit_ttl(key)
      expires_at = get_first_value(<<-SQL, [key])
        SELECT expires_at FROM rate_limits WHERE key_name = ?
      SQL
      
      return -1 unless expires_at
      
      ttl = expires_at - Time.now.to_i
      ttl > 0 ? ttl : -1
    end
    
    # URL post prevention (replaces Redis URL deduplication)
    def check_url_posted_recently(url)
      cleanup_expired_url_posts
      
      get_first_value(<<-SQL, [url, Time.now.to_i])
        SELECT news_id FROM url_posts 
        WHERE url = ? AND expires_at > ?
      SQL
    end
    
    def set_url_posted(url, news_id, expires_in_seconds)
      expires_at = Time.now.to_i + expires_in_seconds
      
      execute(<<-SQL, [url, news_id, expires_at])
        INSERT OR REPLACE INTO url_posts (url, news_id, expires_at)
        VALUES (?, ?, ?)
      SQL
    end
    
    # Pagination helper
    def paginate(query, params = [], offset = 0, limit = 10)
      paginated_query = query + " LIMIT ? OFFSET ?"
      execute(paginated_query, params + [limit, offset])
    end
    
    # Prepared statement cache (for performance)
    def prepare_cached(sql)
      @prepared_statements ||= {}
      @prepared_statements[sql] ||= connection.prepare(sql)
    end
    
    private
    
    def cleanup_expired_items_if_exist
      return unless tables_exist?
      cleanup_expired_items
    end
    
    def cleanup_expired_items
      cleanup_expired_rate_limits
      cleanup_expired_url_posts
      cleanup_expired_reset_tokens_safe
    end

    def cleanup_expired_reset_tokens_safe
      # Only cleanup if table exists
      begin
        execute("DELETE FROM password_reset_tokens WHERE expires_at < ?", [Time.now.to_i])
      rescue SQLite3::SQLException => e
        # Table doesn't exist yet, skip cleanup
      end
    end
    
    def tables_exist?
      # Check if the main tables exist
      result = execute("SELECT name FROM sqlite_master WHERE type='table' AND name='rate_limits'")
      !result.empty?
    rescue SQLite3::SQLException
      false
    end
    
    def cleanup_expired_rate_limits
      execute("DELETE FROM rate_limits WHERE expires_at <= ?", Time.now.to_i)
    end
    
    def cleanup_expired_url_posts  
      execute("DELETE FROM url_posts WHERE expires_at <= ?", Time.now.to_i)
    end

  end
end

# Password Reset Token Management Module
module TokenDB
  def self.create_password_reset_token(user_id, token, expires_at)
    Database.execute(<<-SQL, [user_id, token, expires_at, Time.now.to_i])
      INSERT INTO password_reset_tokens (user_id, token, expires_at, created_at)
      VALUES (?, ?, ?, ?)
    SQL
  end

  def self.get_password_reset_token(token)
    Database.get_first_row(<<-SQL, [token, Time.now.to_i])
      SELECT * FROM password_reset_tokens
      WHERE token = ? AND used = 0 AND expires_at > ?
    SQL
  end

  def self.use_password_reset_token(token)
    Database.execute(<<-SQL, [token])
      UPDATE password_reset_tokens
      SET used = 1
      WHERE token = ?
    SQL
  end

  def self.cleanup_expired_reset_tokens
    Database.execute(<<-SQL, [Time.now.to_i])
      DELETE FROM password_reset_tokens
      WHERE expires_at < ?
    SQL
  end
end

# User-related database operations
module UserDB
  
  def self.create_user(username, password_hash, email = '')
    ctime = Time.now.to_i
    user_id = Database.increment_counter('users_count')
    auth_token = SecureRandom.hex(20)
    apisecret = SecureRandom.hex(20)
    
    Database.transaction do
      Database.execute(<<-SQL, [user_id, username, password_hash, ctime, 1, '', email, auth_token, apisecret, '', ctime, 0, 0])
        INSERT INTO users (
          id, username, password, ctime, karma, about, email,
          auth, apisecret, flags, karma_incr_time, pwd_reset, replies
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
    
    [auth_token, apisecret, user_id]
  end
  
  def self.get_user_by_id(user_id)
    Database.get_first_row("SELECT * FROM users WHERE id = ?", user_id)
  end
  
  def self.get_user_by_username(username)
    Database.get_first_row("SELECT * FROM users WHERE username = ? COLLATE NOCASE", username)
  end
  
  def self.get_user_by_auth(auth_token)
    Database.get_first_row("SELECT * FROM users WHERE auth = ?", auth_token)
  end
  
  def self.update_user_field(user_id, field, value)
    Database.execute("UPDATE users SET #{field} = ? WHERE id = ?", [value, user_id])
  end
  
  def self.increment_user_karma(user_id, amount)
    Database.execute("UPDATE users SET karma = karma + ? WHERE id = ?", [amount, user_id])
  end
  
  def self.username_exists?(username)
    !Database.get_first_value("SELECT 1 FROM users WHERE username = ? COLLATE NOCASE", username).nil?
  end
end

# News-related database operations  
module NewsDB
  
  def self.create_news(title, url, user_id, text = nil)
    ctime = Time.now.to_i
    news_id = Database.increment_counter('news_count')
    
    # Handle text posts
    if text && !text.empty? && (url.nil? || url.empty?)
      url = "text://#{text[0...4096]}"
    end
    
    Database.transaction do
      Database.execute(<<-SQL, [news_id, title, url, user_id, ctime, 0, 0, 0, 0, 0, 0])
        INSERT INTO news (
          id, title, url, user_id, ctime, score, rank, up, down, comments, del
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
    
    news_id
  end
  
  def self.get_news_by_id(news_id, include_vote_info = false)
    news = Database.get_first_row("SELECT * FROM news WHERE id = ?", news_id)
    return nil unless news
    
    # Add username
    user = Database.get_first_row("SELECT username FROM users WHERE id = ?", news['user_id'])
    news['username'] = user ? user['username'] : 'deleted_user'
    
    if include_vote_info
      # Add vote counts
      news['up'] = Database.get_first_value(<<-SQL, news_id) || 0
        SELECT COUNT(*) FROM votes 
        WHERE item_type = 'news' AND item_id = ? AND vote_type = 'up'
      SQL
      
      news['down'] = Database.get_first_value(<<-SQL, news_id) || 0
        SELECT COUNT(*) FROM votes 
        WHERE item_type = 'news' AND item_id = ? AND vote_type = 'down'
      SQL
    end
    
    news
  end
  
  def self.get_news_list(order_by = 'rank DESC', offset = 0, limit = 30, where_clause = nil)
    base_query = <<-SQL
      SELECT n.*, u.username,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'news' AND v.item_id = n.id AND v.vote_type = 'up') as up,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'news' AND v.item_id = n.id AND v.vote_type = 'down') as down
      FROM news n
      JOIN users u ON n.user_id = u.id
      WHERE n.del = 0
    SQL
    
    if where_clause
      base_query += " AND #{where_clause}"
    end
    
    base_query += " ORDER BY #{order_by} LIMIT ? OFFSET ?"
    
    Database.execute(base_query, [limit, offset])
  end
  
  def self.get_top_news(offset = 0, limit = 30)
    get_news_list('n.rank DESC', offset, limit)
  end
  
  def self.get_latest_news(offset = 0, limit = 30)
    get_news_list('n.ctime DESC', offset, limit)
  end
  
  def self.get_user_news(user_id, offset = 0, limit = 30)
    query = <<-SQL
      SELECT n.*, u.username,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'news' AND v.item_id = n.id AND v.vote_type = 'up') as up,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'news' AND v.item_id = n.id AND v.vote_type = 'down') as down
      FROM news n
      JOIN users u ON n.user_id = u.id
      WHERE n.del = 0 AND n.user_id = ?
      ORDER BY n.ctime DESC
      LIMIT ? OFFSET ?
    SQL
    
    Database.execute(query, [user_id, limit, offset])
  end
  
  def self.get_posted_news_by_user(user_id, offset = 0, limit = 30)
    get_user_news(user_id, offset, limit)
  end
  
  def self.get_user_saved_news(user_id, offset = 0, limit = 30)
    query = <<-SQL
      SELECT n.*, u.username,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'news' AND v.item_id = n.id AND v.vote_type = 'up') as up,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'news' AND v.item_id = n.id AND v.vote_type = 'down') as down
      FROM news n
      JOIN users u ON n.user_id = u.id
      JOIN votes v ON v.item_type = 'news' AND v.item_id = n.id
      WHERE v.user_id = ? AND v.vote_type = 'up' AND n.del = 0
      ORDER BY v.ctime DESC
      LIMIT ? OFFSET ?
    SQL
    
    Database.execute(query, [user_id, limit, offset])
  end
  
  def self.update_news_score_and_rank(news_id, score, rank)
    Database.execute(<<-SQL, [score, rank, news_id])
      UPDATE news SET score = ?, rank = ? WHERE id = ?
    SQL
  end
  
  def self.update_news_field(news_id, field, value)
    Database.execute("UPDATE news SET #{field} = ? WHERE id = ?", [value, news_id])
  end
  
  def self.increment_news_field(news_id, field, amount = 1)
    Database.execute("UPDATE news SET #{field} = #{field} + ? WHERE id = ?", [amount, news_id])
  end
  
  def self.edit_news(news_id, title, url, text, user_id, is_admin = false)
    news = get_news_by_id(news_id)
    return false if !news || (news['user_id'].to_i != user_id.to_i && !is_admin)
    
    # Check if news is still editable (within edit time limit for non-admins)
    news_age = Time.now.to_i - news['ctime'].to_i
    return false if news_age > NewsEditTime && !is_admin
    
    # Handle text posts
    textpost = url.length == 0
    if textpost
      url = "text://#{text[0...4096]}"
    end
    
    # Check for duplicate URLs if URL changed
    if !textpost && url != news['url']
      existing_news = Database.get_first_value("SELECT id FROM url_posts WHERE url = ?", url)
      return false if existing_news
      
      # Update URL tracking
      Database.transaction do
        Database.execute("DELETE FROM url_posts WHERE news_id = ?", news_id)
        Database.execute("INSERT INTO url_posts (url, news_id, ctime) VALUES (?, ?, ?)",
                        [url, news_id, Time.now.to_i])
      end
    end
    
    # Update the news
    Database.execute("UPDATE news SET title = ?, url = ? WHERE id = ?",
                    [title, url, news_id])
    
    news_id
  end
  
  def self.del_news(news_id, user_id)
    news = get_news_by_id(news_id)
    return false if !news || (news['user_id'].to_i != user_id.to_i && !user_is_admin($user))
    
    # Check if news is still editable (within edit time limit for non-admins)
    news_age = Time.now.to_i - news['ctime'].to_i
    return false if news_age > NewsEditTime && !user_is_admin($user)
    
    Database.execute("UPDATE news SET del = 1 WHERE id = ?", news_id)
    true
  end
end

# Vote-related database operations
module VoteDB
  
  def self.vote_exists?(user_id, item_type, item_id)
    !Database.get_first_value(<<-SQL, [user_id, item_type, item_id]).nil?
      SELECT 1 FROM votes 
      WHERE user_id = ? AND item_type = ? AND item_id = ?
    SQL
  end
  
  def self.cast_vote(user_id, item_type, item_id, vote_type)
    return false if vote_exists?(user_id, item_type, item_id)
    
    ctime = Time.now.to_i
    
    begin
      Database.execute(<<-SQL, [user_id, item_type, item_id, vote_type, ctime])
        INSERT INTO votes (user_id, item_type, item_id, vote_type, ctime)
        VALUES (?, ?, ?, ?, ?)
      SQL
      true
    rescue SQLite3::ConstraintException
      false
    end
  end
  
  def self.get_user_vote(user_id, item_type, item_id)
    Database.get_first_value(<<-SQL, [user_id, item_type, item_id])
      SELECT vote_type FROM votes
      WHERE user_id = ? AND item_type = ? AND item_id = ?
    SQL
  end
  
  def self.get_vote_counts(item_type, item_id)
    result = Database.get_first_row(<<-SQL, [item_type, item_id])
      SELECT 
        SUM(CASE WHEN vote_type = 'up' THEN 1 ELSE 0 END) as up_count,
        SUM(CASE WHEN vote_type = 'down' THEN 1 ELSE 0 END) as down_count
      FROM votes
      WHERE item_type = ? AND item_id = ?
    SQL
    
    [result['up_count'] || 0, result['down_count'] || 0]
  end
  
  def self.vote_comment(news_id, comment_id, user_id, vote_type)
    # Cast vote on comment using comment type and id
    cast_vote(user_id, 'comment', comment_id, vote_type.to_s)
  end
end