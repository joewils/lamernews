# SQLite Comments System for Lamer News
# Replaces the Redis-based comments system

require_relative 'database'

class SQLiteComments
  
  def initialize(sort_proc = nil)
    @sort_proc = sort_proc
  end
  
  # Fetch a single comment by news_id and comment_id
  def fetch(news_id, comment_id)
    comment = Database.get_first_row(<<-SQL, [comment_id, news_id])
      SELECT * FROM comments WHERE id = ? AND news_id = ?
    SQL
    
    return nil unless comment
    
    # Add thread_id for compatibility with existing code
    comment['thread_id'] = news_id.to_i
    comment['id'] = comment_id.to_i
    
    # Load vote information
    load_comment_votes(comment)
    
    comment
  end
  
  # Insert a new comment
  def insert(news_id, comment_data)
    raise "no parent_id field" unless comment_data.has_key?('parent_id')
    
    # Validate parent exists if not root comment
    if comment_data['parent_id'] != -1
      parent = fetch(news_id, comment_data['parent_id'])
      return false unless parent
    end
    
    ctime = Time.now.to_i
    
    Database.transaction do
      # Insert the comment
      Database.execute(<<-SQL, [news_id, comment_data['parent_id'], comment_data['user_id'], comment_data['body'], ctime, 0, 0])
        INSERT INTO comments (news_id, parent_id, user_id, body, ctime, score, del)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      
      comment_id = Database.last_insert_row_id
      
      # Auto-upvote from the comment author
      if comment_data['user_id']
        VoteDB.cast_vote(comment_data['user_id'], 'comment', comment_id, 'up')
      end
      
      # Increment news comment count
      NewsDB.increment_news_field(news_id, 'comments', 1)
      
      comment_id
    end
  end
  
  # Edit an existing comment
  def edit(news_id, comment_id, updates)
    comment = fetch(news_id, comment_id)
    return false unless comment
    
    # Build update query dynamically based on provided fields
    set_clauses = []
    values = []
    
    updates.each do |field, value|
      set_clauses << "#{field} = ?"
      values << value
    end
    
    return true if set_clauses.empty?
    
    values << comment_id
    values << news_id
    
    Database.execute(<<-SQL, values)
      UPDATE comments SET #{set_clauses.join(', ')} 
      WHERE id = ? AND news_id = ?
    SQL
    
    true
  end
  
  # Mark a comment as deleted
  def del_comment(news_id, comment_id)
    edit(news_id, comment_id, {'del' => 1})
  end
  
  # Remove an entire thread (all comments for a news item)
  def remove_thread(news_id)
    Database.execute("DELETE FROM comments WHERE news_id = ?", news_id)
  end
  
  # Count comments in a thread
  def comments_in_thread(news_id)
    Database.get_first_value(<<-SQL, news_id) || 0
      SELECT COUNT(*) FROM comments WHERE news_id = ? AND del = 0
    SQL
  end
  
  # Fetch all comments in a thread organized by parent
  def fetch_thread(news_id)
    comments = Database.execute(<<-SQL, news_id)
      SELECT c.*, u.username 
      FROM comments c
      LEFT JOIN users u ON c.user_id = u.id
      WHERE c.news_id = ?
      ORDER BY c.ctime ASC
    SQL
    
    byparent = {}
    
    comments.each do |comment|
      # Load vote information
      load_comment_votes(comment)
      
      # Add compatibility fields
      comment['id'] = comment['id'].to_i
      comment['thread_id'] = news_id.to_i
      
      parent_id = comment['parent_id'].to_i
      byparent[parent_id] = [] unless byparent.has_key?(parent_id)
      byparent[parent_id] << comment
    end
    
    byparent
  end
  
  # Render comments with callback (maintains API compatibility)
  def render_comments(news_id, root = -1, &block)
    byparent = fetch_thread(news_id)
    if byparent[-1]
      render_comments_rec(byparent, root, 0, block)
    end
    # Always return nil/empty to maintain compatibility - HTML is built via block
    nil
  end
  
  # Get comments posted by a specific user
  def get_user_comments(user_id, offset = 0, limit = 10)
    total_count = Database.get_first_value(<<-SQL, user_id) || 0
      SELECT COUNT(*) FROM comments WHERE user_id = ? AND del = 0
    SQL
    
    comments = Database.execute(<<-SQL, [user_id, limit, offset])
      SELECT c.*, u.username 
      FROM comments c
      LEFT JOIN users u ON c.user_id = u.id
      WHERE c.user_id = ? AND c.del = 0
      ORDER BY c.ctime DESC
      LIMIT ? OFFSET ?
    SQL
    
    comments.each do |comment|
      load_comment_votes(comment)
      comment['thread_id'] = comment['news_id']
    end
    
    [comments, total_count]
  end
  
  # Vote on a comment
  def vote_comment(news_id, comment_id, user_id, vote_type)
    comment = fetch(news_id, comment_id)
    return false unless comment
    
    success = VoteDB.cast_vote(user_id, 'comment', comment_id, vote_type)
    
    if success
      # Update comment score
      up_count, down_count = VoteDB.get_vote_counts('comment', comment_id)
      new_score = up_count - down_count
      edit(news_id, comment_id, {'score' => new_score})
    end
    
    success
  end
  
  private
  
  # Recursive rendering (maintains compatibility with original implementation)
  def render_comments_rec(byparent, parent_id, level, block)
    thislevel = byparent[parent_id]
    return "" unless thislevel
    
    thislevel = @sort_proc.call(thislevel, level) if @sort_proc
    
    thislevel.each do |comment|
      comment['level'] = level
      parents = byparent[comment['id']]
      
      # Render the comment if not deleted, or if deleted but has replies
      if !comment['del'] || comment['del'].to_i == 0 || parents
        block.call(comment) 
      end
      
      if parents
        render_comments_rec(byparent, comment['id'], level + 1, block)
      end
    end
  end
  
  # Load vote information for a comment (for compatibility)
  def load_comment_votes(comment)
    comment_id = comment['id']
    
    # Get upvote user IDs
    upvote_users = Database.execute(<<-SQL, comment_id)
      SELECT user_id FROM votes 
      WHERE item_type = 'comment' AND item_id = ? AND vote_type = 'up'
    SQL
    comment['up'] = upvote_users.map { |row| row['user_id'].to_i }
    
    # Get downvote user IDs  
    downvote_users = Database.execute(<<-SQL, comment_id)
      SELECT user_id FROM votes
      WHERE item_type = 'comment' AND item_id = ? AND vote_type = 'down'  
    SQL
    comment['down'] = downvote_users.map { |row| row['user_id'].to_i }
    
    # Calculate score
    comment['score'] = comment['up'].length - comment['down'].length
  end
end

# Comment-related database operations module
module CommentDB
  
  def self.create_comment(news_id, user_id, parent_id, body)
    ctime = Time.now.to_i
    
    Database.transaction do
      Database.execute(<<-SQL, [news_id, parent_id, user_id, body, ctime, 0, 0])
        INSERT INTO comments (news_id, parent_id, user_id, body, ctime, score, del)
        VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      
      comment_id = Database.last_insert_row_id
      
      # Auto-upvote from author
      VoteDB.cast_vote(user_id, 'comment', comment_id, 'up')
      
      # Update comment count on news
      NewsDB.increment_news_field(news_id, 'comments', 1)
      
      # Update user's reply count if this is a reply to another user
      if parent_id != -1
        parent_comment = Database.get_first_row(<<-SQL, [parent_id, news_id])
          SELECT user_id FROM comments WHERE id = ? AND news_id = ?
        SQL
        
        if parent_comment && parent_comment['user_id'] != user_id
          UserDB.update_user_field(parent_comment['user_id'], 'replies', 
            Database.get_first_value("SELECT replies FROM users WHERE id = ?", parent_comment['user_id']).to_i + 1
          )
        end
      end
      
      comment_id
    end
  end
  
  def self.get_comment(news_id, comment_id)
    Database.get_first_row(<<-SQL, [comment_id, news_id])
      SELECT c.*, u.username 
      FROM comments c
      LEFT JOIN users u ON c.user_id = u.id  
      WHERE c.id = ? AND c.news_id = ?
    SQL
  end
  
  def self.update_comment(news_id, comment_id, body)
    Database.execute(<<-SQL, [body, comment_id, news_id])
      UPDATE comments SET body = ?, del = 0 WHERE id = ? AND news_id = ?
    SQL
  end
  
  def self.delete_comment(news_id, comment_id)
    Database.transaction do
      # Mark as deleted
      Database.execute(<<-SQL, [comment_id, news_id])
        UPDATE comments SET del = 1 WHERE id = ? AND news_id = ?
      SQL
      
      # Decrement news comment count
      NewsDB.increment_news_field(news_id, 'comments', -1)
    end
  end
  
  def self.get_thread_comments(news_id)
    Database.execute(<<-SQL, news_id)
      SELECT c.*, u.username,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'comment' AND v.item_id = c.id AND v.vote_type = 'up') as up_count,
             (SELECT COUNT(*) FROM votes v WHERE v.item_type = 'comment' AND v.item_id = c.id AND v.vote_type = 'down') as down_count
      FROM comments c
      LEFT JOIN users u ON c.user_id = u.id
      WHERE c.news_id = ?
      ORDER BY c.ctime ASC
    SQL
  end
  
  def self.get_user_comments(user_id, offset = 0, limit = 10)
    total = Database.get_first_value(<<-SQL, user_id) || 0
      SELECT COUNT(*) FROM comments WHERE user_id = ? AND del = 0
    SQL
    
    comments = Database.execute(<<-SQL, [user_id, limit, offset])
      SELECT c.*, u.username, n.title as news_title
      FROM comments c
      LEFT JOIN users u ON c.user_id = u.id
      LEFT JOIN news n ON c.news_id = n.id
      WHERE c.user_id = ? AND c.del = 0
      ORDER BY c.ctime DESC
      LIMIT ? OFFSET ?
    SQL
    
    [comments, total]
  end
end