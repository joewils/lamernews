# Modified to support SQLite by GitHub Copilot & Joe Wilson, September 2025
#
# Copyright 2011 Salvatore Sanfilippo. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY SALVATORE SANFILIPPO ''AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
# NO EVENT SHALL SALVATORE SANFILIPPO OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Salvatore Sanfilippo.

require_relative 'app_config'
require 'rubygems'
require_relative 'database'
require_relative 'comments'
require_relative 'page'
require 'sinatra'
require 'json'
require 'digest/sha1'
require 'digest/md5'
require 'bcrypt'
require_relative 'mail'
require_relative 'about'
require 'uri'
require 'securerandom'

Version = "0.13.0-sqlite"

def setup_database
    Database.setup(DatabasePath)
end

before do
    setup_database
    H = HTMLGen.new if !defined?(H)
    if !defined?(Comments)
        Comments = SQLiteComments.new(proc{|c,level|
            c.sort {|a,b|
                ascore = compute_comment_score a
                bscore = compute_comment_score b
                if ascore == bscore
                    # If score is the same favor newer comments
                    b['ctime'].to_i <=> a['ctime'].to_i
                else
                    # If score is different order by score.
                    # FIXME: do something smarter favouring newest comments
                    # but only in the short time.
                    bscore <=> ascore
                end
            }
        })
    end
    $user = nil
    auth_user(request.cookies['auth'])
    increment_karma_if_needed if $user
end

get '/' do
    H.set_title "#{SiteName} - #{SiteDescription}"
    news,numitems = get_top_news
    H.page {
        H.h2 {"Top news"}+news_list_to_html(news)
    }
end

get '/rss' do
    content_type 'text/xml', :charset => 'utf-8'
    news,count = get_latest_news
    H.rss(:version => "2.0", "xmlns:atom" => "http://www.w3.org/2005/Atom") {
        H.channel {
            H.title {
                "#{SiteName}"
            } + " " +
            H.link {
                "#{SiteUrl}"
            } + " " +
            H.description {
                "Description pending"
            } + " " +
            news_list_to_rss(news)
        }
    }
end

get '/latest' do
    redirect '/latest/0'
end

get '/latest/:start' do
    start = params[:start].to_i
    H.set_title "Latest news - #{SiteName}"
    paginate = {
        :get => Proc.new {|start,count|
            get_latest_news(start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => LatestNewsPerPage,
        :link => "/latest/$"
    }
    H.page {
        H.h2 {"Latest news"}+
        H.section(:id => "newslist") {
            list_items(paginate)
        }
    }
end

get '/random' do
    counter = Database.get_counter('news_count') || 0
    if counter > 0
        random = 1 + rand(counter)
        news = NewsDB.get_news_by_id(random)
        if news && news['del'].to_i != 1
            redirect "/news/#{random}"
        else
            redirect "/news/#{counter}"
        end
    else
        redirect "/"
    end
end

# Admin panel route
get '/admin' do
    redirect "/" if !$user || !user_is_admin?($user)
    H.set_title "Admin Section - #{SiteName}"
    H.page {
        H.div(:id => "adminlinks") {
            H.h2 {"Admin"} +
            H.h3 {"Site stats"} +
            generate_site_stats +
            H.h3 {"Developer tools"} +
            H.ul {
                H.li {
                    H.a(:href => "/recompute") {
                        "Recompute news score and rank (may be slow!)"
                    }
                } +
                H.li {
                    H.a(:href => "/?debug=1") {
                        "Show annotated home page"
                    }
                }
            }
        }
    }
end

# Recompute news scores and rankings (admin only)
get '/recompute' do
    if $user and user_is_admin?($user)
        # Rate limit recompute operations (10 seconds for testing, normally 3600)
        if rate_limit_by_ip(10, "admin", "recompute", $user['id'])
            halt 500, "Rate limit exceeded. Please wait 10 seconds before running recompute again."
        end
        
        # Get all non-deleted news
        news_list = Database.execute("SELECT id FROM news WHERE del != 1")
        recomputed_count = 0
        
        news_list.each do |news_row|
            news_id = news_row[0] # Database.execute returns array of arrays, first column is id
            news = NewsDB.get_news_by_id(news_id)
            next if !news
            
            score = compute_news_score(news)
            rank = compute_news_rank(news)
            
            # Update news with new score and rank
            Database.execute("UPDATE news SET score = ?, rank = ? WHERE id = ?", 
                            score, rank, news['id'])
            recomputed_count += 1
        end
        
        H.page {
            H.p {"Done. Recomputed scores and ranks for #{recomputed_count} news items."} +
            H.p {"Note: This operation is rate-limited to once per hour per admin."}
        }
    else
        redirect "/"
    end
end

get '/saved/:start' do
    redirect "/login" if !$user
    start = params[:start].to_i
    H.set_title "Saved news - #{SiteName}"
    paginate = {
        :get => Proc.new {|start,count|
            get_saved_news($user['id'],start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => SavedNewsPerPage,
        :link => "/saved/$"
    }
    H.page {
        H.h2 {"Your saved news"}+
        H.section(:id => "newslist") {
            list_items(paginate)
        }
    }
end

get '/login' do
    H.set_title "Login - #{SiteName}"
    H.page {
        H.div(:id => "login") {
            H.form(:name=>"f") {
                H.label(:for => "username") {"username"}+
                H.inputtext(:id => "username", :name => "username")+
                H.br+
                H.label(:for => "password") {"password"}+
                H.inputpass(:id => "password", :name => "password")+
                H.br+
                H.div(:id => "email_field", :style => "display: none;") {
                    H.label(:for => "email") {"email (optional)"}+
                    H.inputtext(:id => "email", :name => "email")+
                    H.br
                }+
                H.checkbox(:name => "register", :value => "1")+
                "create account"+
                H.br+
                H.submit(:name => "do_login", :value => "Login")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.a(:href=>"/reset-password") {"reset password"}+
        H.script() {'
            $(function() {
                $("form[name=f]").submit(login);
                
                // Show/hide email field when register checkbox is toggled
                $("input[name=register]").change(function() {
                    if (this.checked) {
                        $("#email_field").show();
                        $("input[name=do_login]").val("Create Account");
                    } else {
                        $("#email_field").hide();
                        $("input[name=do_login]").val("Login");
                    }
                });
            });
        '}
    }
end

get '/logout' do
    if $user
        update_auth_token($user['id'])
        session[:auth_token] = nil
        $user = nil
    end
    redirect "/"
end

# Password reset form
get '/reset-password' do
    H.set_title "Reset Password - #{SiteName}"
    H.page {
        H.p {
            "Welcome to the password reset procedure. Please specify the username and the email address you used to register to the site. "+H.br+
            H.b {"Note that if you did not specify an email it is impossible for you to recover your password."}
        }+
        H.div(:id => "login") {
            H.form(:name=>"f") {
                H.label(:for => "username") {"username"}+
                H.inputtext(:id => "username", :name => "username")+
                H.label(:for => "email") {"email"}+
                H.inputtext(:id => "email", :name => "email")+H.br+
                H.submit(:name => "do_reset", :value => "Reset password")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("form[name=f]").submit(function(event) {
                    event.preventDefault();
                    $.post("/api/reset-password", {
                        username: $("#username").val(),
                        email: $("#email").val()
                    }, function(data) {
                        if (data.status == "ok") {
                            window.location.href = "/reset-password-ok";
                        } else {
                            $("#errormsg").html(data.error);
                        }
                    }, "json");
                });
            });
        '}
    }
end

# Password reset confirmation
get '/reset-password-ok' do
    H.set_title "Password Reset Sent - #{SiteName}"
    H.page {
        H.p {
            "An email with instructions to reset your password has been sent to the email address registered with your account."
        }+
        H.p {
            H.a(:href=>"/") {"Back to homepage"}
        }
    }
end

# New password form (accessed via email link)
get '/set-new-password' do
    token = params[:token]
    if !token || token.empty?
        redirect "/"
    end
    
    H.set_title "Set New Password - #{SiteName}"
    H.page {
        H.div(:id => "login") {
            H.form(:name=>"f") {
                H.inputhidden(:name => "token", :value => token)+
                H.label(:for => "password") {"New password"}+
                H.inputpass(:id => "password", :name => "password")+H.br+
                H.label(:for => "password2") {"Confirm password"}+
                H.inputpass(:id => "password2", :name => "password2")+H.br+
                H.submit(:name => "set_password", :value => "Set password")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("form[name=f]").submit(function(event) {
                    event.preventDefault();
                    if ($("#password").val() != $("#password2").val()) {
                        $("#errormsg").html("Passwords do not match.");
                        return;
                    }
                    $.post("/api/set-new-password", {
                        token: $("input[name=token]").val(),
                        password: $("#password").val()
                    }, function(data) {
                        if (data.status == "ok") {
                            window.location.href = "/login";
                        } else {
                            $("#errormsg").html(data.error);
                        }
                    }, "json");
                });
            });
        '}
    }
end

# Individual comment view
get "/comment/:news_id/:comment_id" do
    news = NewsDB.get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"], params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    H.set_title "#{news["title"]} - #{SiteName}"    
    H.page {
        H.section(:id => "newslist") {
            news_to_html(news)
        }+
        render_comment_subthread(comment, H.h2 {"Replies"})
    }
end

# Reply to comment form
get "/reply/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = NewsDB.get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"], params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = UserDB.get_user_by_id(comment["user_id"])

    H.set_title "Reply to comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user)+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news["id"])+
            H.inputhidden(:name => "comment_id", :value => -1)+
            H.inputhidden(:name => "parent_id", :value => params["comment_id"])+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
            H.button(:name => "post_comment", :value => "Reply")
        }+H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

# Edit comment form
get "/editcomment/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = NewsDB.get_news_by_id(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = Comments.fetch(params["news_id"], params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = UserDB.get_user_by_id(comment["user_id"])
    halt(500,"Permission denied.") if $user['id'].to_i != user['id'].to_i

    H.set_title "Edit comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user)+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news["id"])+
            H.inputhidden(:name => "comment_id",:value => params["comment_id"])+
            H.inputhidden(:name => "parent_id", :value => -1)+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {
                H.entities comment['body']
            }+H.br+
            H.button(:name => "post_comment", :value => "Edit")
        }+H.div(:id => "errormsg"){}+
        H.note {
            "Note: to remove the comment, remove all the text and press Edit."
        }+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get '/submit' do
    redirect "/" if !$user
    H.set_title "Submit a new story - #{SiteName}"
    H.page {
        H.div(:id => "submitform") {
            H.h2 {"Submit a new story"}+
            H.form(:name=>"f") {
                H.label(:for => "title") {"title"}+
                H.inputtext(:id => "title", :name => "title", :size => 80, :value => params[:t] ? H.entities(params[:t]) : "")+
                H.br+
                H.label(:for => "url") {"url"}+
                H.inputtext(:id => "url", :name => "url", :size => 80, :value => params[:u] ? H.entities(params[:u]) : "")+
                H.br+
                "or if you don't have an url type some text"+
                H.br+
                H.label(:for => "text") {"text"}+
                H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {params[:text] ? H.entities(params[:text]) : ""}+
                H.br+
                H.submit(:name => "do_submit", :value => "Submit")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("form[name=f]").submit(submit);
            });
        '}
    }
end

get "/news/:news_id" do
    news = get_news_by_id(params[:news_id])
    halt(404,"404 - This news does not exist.") if !news
    # Show news detail with comments
    title = news['title'] || "Untitled"
    H.set_title title+" - "+SiteName
    H.page {
        render_news(news) +
        render_comment_form_for_news(news['id']) +
        H.div(:id => "comments") {
            H.h2 {"Comments"}+
            render_comments_for_news(news['id'])
        }+
        H.script() {'
            $(function() {
                $("form[name=f]").submit(post_comment);
                
                // Initialize comment voting handlers
                $("#comments article.comment").each(function(i,comment) {
                    attach_voting_handlers(comment,"comment");
                });
            });
        '}
    }
end

# User reply notifications
get '/replies' do
    redirect "/login" if !$user
    comments, count = Comments.get_user_comments($user['id'], 0, SubthreadsInRepliesPage)
    H.set_title "Your threads - #{SiteName}"
    H.page {
        # Reset reply count
        Database.execute("UPDATE users SET replies = 0 WHERE id = ?", $user['id'])
        
        H.h2 {"Your threads"}+
        H.div("id" => "comments") {
            aux = ""
            comments.each{|c|
                aux << render_comment_subthread(c)
            }
            aux
        }
    }
end

# User comment history
get '/usercomments/:username/:start' do
    start = params[:start].to_i
    user = UserDB.get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user

    H.set_title "#{user['username']} comments - #{SiteName}"
    paginate = {
        :get => Proc.new {|start,count|
            Comments.get_user_comments(user['id'], start, count)
        },
        :render => Proc.new {|comment|
            u = UserDB.get_user_by_id(comment["user_id"])
            comment_to_html(comment, u)
        },
        :start => start,
        :perpage => UserCommentsPerPage,
        :link => "/usercomments/#{CGI.escape(user['username'])}/$"
    }
    H.page {
        H.h2 {"#{H.entities user['username']} comments"}+
        H.div("id" => "comments") {
            list_items(paginate)
        }
    }
end

# User news listings  
get '/usernews/:username/:start' do
    start = params[:start].to_i
    user = UserDB.get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user

    page_title = "News posted by #{user['username']}"
    H.set_title "#{page_title} - #{SiteName}"
    
    paginate = {
        :get => Proc.new {|start,count|
            get_posted_news(user['id'], start, count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => LatestNewsPerPage,
        :link => "/usernews/#{CGI.escape(user['username'])}/$"
    }
    
    H.page {
        H.h2 {page_title}+
        H.section(:id => "newslist") {
            list_items(paginate)
        }
    }
end

get '/user/:username' do
    user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user
    posted_news,posted_comments = get_user_counts(user['id'])
    H.set_title "#{user['username']} - #{SiteName}"
    owner = $user && ($user['id'].to_i == user['id'].to_i)
    H.page {
        H.div(:class => "userinfo") {
            H.h2(:style => "") {H.entities user['username']}+
            H.pre {
                H.entities user['about']
            }+
            H.ul {
                H.li {
                    H.b {"created "}+
                    str_elapsed(user['ctime'].to_i)
                }+
                H.li {H.b {"karma "}+ "#{user['karma']} points"}+
                H.li {H.b {"posted news "}+posted_news.to_s}+
                H.li {H.b {"posted comments "}+posted_comments.to_s}+
                if owner
                    H.li {H.a(:href=>"/saved/0") {"saved news"}}
                else "" end+
                H.li {
                    H.a(:href=>"/usercomments/"+CGI.escape(user['username'])+
                               "/0") {
                        "user comments"
                    }
                }+
                H.li {
                    H.a(:href=>"/usernews/"+CGI.escape(user['username'])+
                               "/0") {
                        "user news"
                    }
                }
            }
        }+if owner
            H.br+H.form(:name=>"f") {
                H.label(:for => "email") {
                    "email (not visible, used for account administration)"
                }+H.br+
                H.inputtext(:id => "email", :name => "email", :size => 40,
                            :value => H.entities(user['email']))+H.br+
                H.label(:for => "password") {
                    "change password (optional)"
                }+H.br+
                H.inputpass(:name => "password", :size => 40)+H.br+
                H.label(:for => "about") {"about"}+H.br+
                H.textarea(:id => "about", :name => "about", :cols => 60, :rows => 10){
                    H.entities(user['about'])
                }+H.br+
                H.button(:name => "update_profile", :value => "Update profile")
            }+
            H.div(:id => "errormsg"){}+
            H.script() {'
                $(function() {
                    $("input[name=update_profile]").click(update_profile);
                });
            '}
        else "" end
    }
end

################################################################################
# User and authentication
################################################################################

# Try to authenticate the user, if the credentials are ok we populate the
# $user global with the user information.
# Otherwise $user is set to nil, so you can test for authenticated user
# just with: if $user ...
#
# Return value: none, the function works by side effect.
def auth_user(auth)
    return if !auth
    user = UserDB.get_user_by_auth(auth)
    $user = user if user
end

# In Lamer News users get karma visiting the site.
# Increment the user karma by KarmaIncrementAmount if the latest increment
# was performed more than KarmaIncrementInterval seconds ago.
#
# Return value: none.
#
# Notes: this function must be called only in the context of a logged in
#        user.
#
# Side effects: the user karma is incremented and the $user hash updated.
def increment_karma_if_needed
    if $user['karma_incr_time'].to_i < (Time.now.to_i-KarmaIncrementInterval)
        UserDB.update_user_field($user['id'], 'karma_incr_time', Time.now.to_i)
        increment_user_karma_by($user['id'], KarmaIncrementAmount)
    end
end

# Increment the user karma by the specified amount and make sure to
# update $user to reflect the change if it is the same user id.
def increment_user_karma_by(user_id, increment)
    UserDB.increment_user_karma(user_id, increment)
    if $user and ($user['id'].to_i == user_id.to_i)
        $user['karma'] = $user['karma'].to_i + increment
    end
end

# Return the specified user karma.
def get_user_karma(user_id)
    return $user['karma'].to_i if $user and (user_id.to_i == $user['id'].to_i)
    user = UserDB.get_user_by_id(user_id)
    user ? user['karma'].to_i : 0
end

# Return the hex representation of an unguessable 160 bit random number.
def get_rand
    SecureRandom.hex(20)
end

# Create a new user with the specified username/password
#
# Return value: the function returns two values, the first is the
#               auth token if the registration succeeded, otherwise
#               is nil. The second is the error message if the function
#               failed (detected testing the first return value).
def create_user(username, password)
    if UserDB.username_exists?(username)
        return nil, nil, "Username is already taken, please try a different one."
    end
    if rate_limit_by_ip(UserCreationDelay, "create_user", request.ip)
        return nil, nil, "Please wait some time before creating a new user."
    end
    
    begin
        auth_token, apisecret, user_id = UserDB.create_user(username, hash_password(password))
        return auth_token, apisecret, nil
    rescue => e
        return nil, nil, "User creation failed: #{e.message}"
    end
end

# Update the specified user authentication token with a random generated
# one. This in other words means to logout all the sessions open for that
# user.
#
# Return value: on success the new token is returned. Otherwise nil.
# Side effect: the auth token is modified.
def update_auth_token(user)
    new_auth_token = get_rand
    UserDB.update_user_field(user['id'], 'auth', new_auth_token)
    return new_auth_token
end

# Turn the password into an hashed one using bcrypt
def hash_password(password, salt=nil)
    # salt parameter is ignored as bcrypt handles salt automatically
    BCrypt::Password.create(password, cost: BCryptCost)
end

# Return the user from the ID.
def get_user_by_id(id)
    UserDB.get_user_by_id(id)
end

# Return the user from the username.
def get_user_by_username(username)
    UserDB.get_user_by_username(username)
end

# Check if the username/password pair identifies an user.
# If so the auth token and form secret are returned, otherwise nil is returned.
def check_user_credentials(username, password)
    user = get_user_by_username(username)
    return nil if !user
    
    # Check if password hash is bcrypt format
    if user['password'].start_with?('$2')
        # New bcrypt hash
        bcrypt_password = BCrypt::Password.new(user['password'])
        return bcrypt_password == password ? [user['auth'], user['apisecret']] : nil
    else
        # Legacy user - passwords cannot be verified without migration
        # Force password reset for security
        return nil
    end
end

# Has the user submitted a news story in the last `NewsSubmissionBreak` seconds?
def submitted_recently
    allowed_to_post_in_seconds > 0
end

# Indicates when the user is allowed to submit another story after the last.
def allowed_to_post_in_seconds
    return 0 if user_is_admin?($user)
    Database.rate_limit_ttl("user:#{$user['id']}:submitted_recently")
end

# Get user post/comment counts
def get_user_counts(user_id)
    posted_news = Database.get_first_value(<<-SQL, user_id) || 0
        SELECT COUNT(*) FROM news WHERE user_id = ? AND del = 0
    SQL
    
    posted_comments = Database.get_first_value(<<-SQL, user_id) || 0
        SELECT COUNT(*) FROM comments WHERE user_id = ? AND del = 0  
    SQL
    
    [posted_news, posted_comments]
end

# Email validation helper function
def is_valid_email?(email)
    return false if email.nil? || email.strip.empty?
    # Simple email regex validation
    email_regex = /\A[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\z/
    !!(email =~ email_regex)
end

# Send password reset email (terminal output for testing)
def send_reset_password_email(user, reset_token)
    puts "\n" + "="*60
    puts "📧 EMAIL NOTIFICATION"  
    puts "="*60
    puts "TO: #{user['email']}"
    puts "FROM: noreply@#{SiteName.downcase.gsub(' ', '')}.com"
    puts "SUBJECT: Password Reset Request for #{SiteName}"
    puts
    puts "Dear #{user['username']},"
    puts
    puts "You have requested a password reset for your account."
    puts "Click the following link to reset your password:"
    puts
    puts "#{SiteUrl}/set-new-password?token=#{reset_token}"
    puts
    puts "This link will expire in #{PasswordResetDelay/3600} hours."
    puts "If you did not request this reset, please ignore this email."
    puts
    puts "Best regards,"
    puts "The #{SiteName} Team"
    puts "="*60
    puts
    $stdout.flush  # Force output to be displayed immediately
end

# Generate secure password reset token
def generate_password_reset_token(user_id)
    token = SecureRandom.hex(32)
    expires_at = Time.now.to_i + PasswordResetDelay
    
    TokenDB.create_password_reset_token(user_id, token, expires_at)
    token
end

# Add the specified set of flags to the user.
# Returns false on error (non existing user), otherwise true is returned.
#
# Current flags:
# 'a'   Administrator.
# 'k'   Karma source, can transfer more karma than owned.
# 'n'   Open links to new windows.
#
def user_add_flags(user_id, flags)
    user = get_user_by_id(user_id)
    return false if !user
    newflags = user['flags']
    flags.each_char{|flag|
        newflags << flag if not user_has_flags?(user, flag)
    }
    UserDB.update_user_field(user_id, 'flags', newflags)
    true
end

# Check if the user has all the specified flags at the same time.
# Returns true or false.
def user_has_flags?(user, flags)
    flags.each_char {|flag|
        return false if not user['flags'].index(flag)
    }
    true
end

def user_is_admin?(user)
    user_has_flags?(user, "a")
end

################################################################################
# News
################################################################################

# Fetch one or more news from SQLite by id.
# Note that we also load other information about the news like
# the username of the poster and other information needed to render
# the news into HTML.
def get_news_by_id(news_ids, opt={})
    result = []
    if !news_ids.is_a? Array
        opt[:single] = true
        news_ids = [news_ids]
    end
    
    news_ids.each do |news_id|
        news = NewsDB.get_news_by_id(news_id, true)
        next unless news
        
        # Adjust rank if too different from the real-time value.
        update_news_rank_if_needed(news) if opt[:update_rank]
        result << news
    end
    
    return opt[:single] ? result[0] : result if result.empty?

    # Load $User vote information if we are in the context of a
    # registered user.
    if $user
        result.each do |news|
            vote = VoteDB.get_user_vote($user['id'], 'news', news['id'])
            news['voted'] = vote.to_sym if vote
        end
    end

    # Return an array if we got an array as input, otherwise
    # the single element the caller requested.
    opt[:single] ? result[0] : result
end

# Generate the main page of the web site, the one where news are ordered by
# rank.
def get_top_news(start=0, count=TopNewsPerPage)
    total_count = Database.get_first_value("SELECT COUNT(*) FROM news WHERE del = 0") || 0
    result = NewsDB.get_top_news(start, count)
    
    # Add vote information for logged-in users
    if $user && result
        result.each do |news|
            vote = VoteDB.get_user_vote($user['id'], 'news', news['id'])
            news['voted'] = vote.to_sym if vote
        end
    end
    
    return result, total_count
end

# Get news in chronological order.
def get_latest_news(start=0, count=LatestNewsPerPage)
    total_count = Database.get_first_value("SELECT COUNT(*) FROM news WHERE del = 0") || 0
    result = NewsDB.get_latest_news(start, count)
    
    # Add vote information for logged-in users
    if $user && result
        result.each do |news|
            vote = VoteDB.get_user_vote($user['id'], 'news', news['id'])
            news['voted'] = vote.to_sym if vote
        end
    end
    
    return result, total_count
end

# Get saved news of current user
def get_saved_news(user_id, start, count)
    result = NewsDB.get_user_saved_news(user_id, start, count)
    total_count = Database.get_first_value(<<-SQL, user_id) || 0
        SELECT COUNT(*) FROM votes v 
        JOIN news n ON v.item_id = n.id 
        WHERE v.user_id = ? AND v.item_type = 'news' AND v.vote_type = 'up' AND n.del = 0
    SQL
    return result, total_count
end

# Get news posted by the specified user
def get_posted_news(user_id, start, count)
    result = NewsDB.get_user_news(user_id, start, count)
    total_count = Database.get_first_value(<<-SQL, user_id) || 0
        SELECT COUNT(*) FROM news WHERE user_id = ? AND del = 0
    SQL
    return result, total_count
end

# Insert new news article
def insert_news(title, url, text, user_id)
    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://#{text[0...CommentMaxLength]}"
    end
    
    # Check for already posted news with the same URL.
    if !textpost
        existing_news = Database.get_first_value("SELECT news_id FROM url_posts WHERE url = ?", url)
        return existing_news if existing_news
    end
    
    # We can finally insert the news.
    ctime = Time.now.to_i
    news_id = NewsDB.create_news(title, url, user_id, text)
    
    # The posting user virtually upvoted the news posting it
    VoteDB.cast_vote(user_id, 'news', news_id, 'up')
    
    # Add the news url for some time to avoid reposts in short time
    Database.set_url_posted(url, news_id, PreventRepostTime) if !textpost
    
    # Set a timeout indicating when the user may post again
    Database.rate_limit_set("user:#{user_id}:submitted_recently", NewsSubmissionBreak)
    
    return news_id
end

# Edit existing news
def edit_news(news_id, title, url, text, user_id)
    is_admin = user_is_admin?($user)
    NewsDB.edit_news(news_id, title, url, text, user_id, is_admin)
end

# Mark an existing news as removed
def del_news(news_id, user_id)
    NewsDB.del_news(news_id, user_id)
end

# Generic API limiting function
def rate_limit_by_ip(delay, *tags)
    key = "limit:" + tags.join(".")
    return true if Database.rate_limit_check(key)
    Database.rate_limit_set(key, delay)
    return false
end

# Updating the rank would require some cron job and worker in theory as
# it is time dependent and we don't want to do any sorting operation at
# page view time. But instead what we do is to compute the rank from the
# score and update it only if there is some sensible error.
def update_news_rank_if_needed(news)
    real_rank = compute_news_rank(news)
    delta_rank = (real_rank - news['rank'].to_f).abs
    if delta_rank > 0.000001
        NewsDB.update_news_score_and_rank(news['id'], news['score'], real_rank)
        news['rank'] = real_rank.to_s
    end
end

# Given the news compute its score.
# No side effects.
def compute_news_score(news)
    up_count, down_count = VoteDB.get_vote_counts('news', news['id'])
    
    # FIXME: For now we are doing a naive sum of votes, without time-based
    # filtering, nor IP filtering.
    score = up_count - down_count
    
    # Now let's add the logarithm of the sum of all the votes, since
    # something with 5 up and 5 down is less interesting than something
    # with 50 up and 50 down.
    votes = up_count + down_count
    if votes > NewsScoreLogStart
        score += Math.log(votes - NewsScoreLogStart) * NewsScoreLogBooster
    end
    score
end

# Given the news compute its rank, that is function of time and score.
#
# The general formula is RANK = SCORE / (AGE ^ AGING_FACTOR)
def compute_news_rank(news)
    age = (Time.now.to_i - news['ctime'].to_i)
    rank = ((news['score'].to_f) * 1000000) / ((age + NewsAgePadding) ** RankAgingFactor)
    rank = -age if (age > TopNewsAgeLimit)
    return rank
end

# Compute the comment score
def compute_comment_score(c)
    upcount = (c['up'] ? c['up'].length : 0)
    downcount = (c['down'] ? c['down'].length : 0)
    upcount - downcount
end

################################################################################
# Utility functions
################################################################################

# Given an unix time in the past returns a string stating how much time
# has elapsed from the specified time, in the form "2 hours ago".
def str_elapsed(t)
    seconds = Time.now.to_i - t
    return "now" if seconds <= 1

    length, label = time_lengths.select{|length, label| seconds >= length }.first
    units = seconds / length
    "#{units} #{label}#{'s' if units > 1} ago"
end

def time_lengths
    [[86400, "day"], [3600, "hour"], [60, "minute"], [1, "second"]]
end

# Show list of items with show-more style pagination.
def list_items(o)
    aux = ""
    o[:start] = 0 if o[:start] < 0
    items, count = o[:get].call(o[:start], o[:perpage])
    items.each{|n|
        aux << o[:render].call(n)
    }
    last_displayed = o[:start] + o[:perpage]
    if last_displayed < count
        nextpage = o[:link].sub("$",
                   (o[:start] + o[:perpage]).to_s)
        aux << H.a(:href => nextpage, :class=> "more") {"[more]"}
    end
    aux
end

# Given a string returns the same string with all the urls converted into
# HTML links. We try to handle the case of an url that is followed by a period
# Like in "I suggest http://google.com." excluding the final dot from the link.
def urls_to_links(s)
    urls = /((https?:\/\/|www\.)([-\w\.]+)+(:\d+)?(\/([\w\/_#:\.\-\%]*(\?\S+)?)?)?)/
    s.gsub(urls) {
        url = text = $1
        url = "http://#{url}" if $2 == 'www.'
        if $1[-1..-1] == '.'
            url = url.chop
            text = text.chop
            '<a rel="nofollow" href="'+url+'">'+text+'</a>.'
        else
            '<a rel="nofollow" href="'+url+'">'+text+'</a>'
        end
    }
end

################################################################################
# HTML Rendering Functions (news and comments)
################################################################################

# Return the host part of the news URL field.
# If the url is in the form text:// nil is returned.
def news_domain(news)
    su = news["url"].split("/")
    domain = (su[0] == "text:") ? nil : su[2]
end

# Assuming the news has an url in the form text:// returns the text
# inside. Otherwise nil is returned.
def news_text(news)
    su = news["url"].split("/")
    (su[0] == "text:") ? news["url"][7..-1] : nil
end

################################################################################
# Navigation and Application Layout
################################################################################

def navbar_replies_link
    return "" if !$user
    count = $user['replies'] || 0
    H.a(:href => "/replies", :class => "replies") {
        "replies"+
        if count.to_i > 0
            H.sup {count}
        else "" end
    }
end

def navbar_admin_link
    return "" if !$user || !user_is_admin?($user)
    H.b {
        H.a(:href => "/admin") {"admin"}
    }
end

def application_header
    navitems = [    ["top","/"],
                    ["latest","/latest/0"],
                    ["random","/random"],                    
                    ["submit","/submit"]]
    navbar = H.nav {
        navitems.map{|ni|
            H.a(:href=>ni[1]) {H.entities ni[0]}
        }.inject{|a,b| a+"\n"+b}+navbar_replies_link+navbar_admin_link
    }
    rnavbar = H.nav(:id => "account") {
        if $user
            H.a(:href => "/user/"+CGI.escape($user['username'])) {
                H.entities $user['username']+" (#{$user['karma']})"
            }+" | "+
            H.a(:href =>
                "/logout?apisecret=#{$user['apisecret']}") {
                "logout"
            }
        else
            H.a(:href => "/login") {"login / register"}
        end
    }
    menu_mobile = H.a(:href => "#", :id => "link-menu-mobile"){"<~>"}
    H.header {
        H.h1 {
            H.a(:href => "/") {H.entities SiteName}+" "+
            H.small {Version}
        }+navbar+" "+rnavbar+" "+menu_mobile
    }
end

def application_footer
    if $user
        apisecret = H.script() {
            "var apisecret = '#{$user['apisecret']}';";
        }
    else
        apisecret = ""
    end
    if KeyboardNavigation == 1
        keyboardnavigation = H.script() {
            "setKeyboardNavigation();"
        } + " " +
        H.div(:id => "keyboard-help", :style => "display: none;") {
            H.div(:class => "keyboard-help-banner banner-background banner") {
            } + " " +
            H.div(:class => "keyboard-help-banner banner-foreground banner") {
                H.div(:class => "primary-message") {
                    "Keyboard shortcuts"
                } + " " +
                H.div(:class => "secondary-message") {
                    H.div(:class => "key") {
                        "j/k:"
                    } + H.div(:class => "desc") {
                        "next/previous item"
                    } + " " +
                    H.div(:class => "key") {
                        "enter:"
                    } + H.div(:class => "desc") {
                        "open link"
                    } + " " +
                    H.div(:class => "key") {
                        "a/z:"
                    } + H.div(:class => "desc") {
                        "up/down vote item"
                    }
                }
            }
        }
    else
        keyboardnavigation = ""
    end
    H.footer {
        links = [
            ["about", "/about"],
            ["source code", FooterSourceUrl],
            ["rss feed", "/rss"],
            ["twitter", FooterTwitterLink],
            ["google group", FooterGoogleGroupLink]
        ]
        links.map{|l| l[1] ?
            H.a(:href => l[1]) {H.entities l[0]} :
            nil
        }.select{|l| l}.join(" | ")
    }+apisecret+keyboardnavigation
end

################################################################################
# HTML Generation
################################################################################

# Turn the news into its HTML representation, that is
# a linked title with buttons to up/down vote plus additional info.
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
def news_to_html(news, show_text = false)
    return H.article(:class => "deleted") {
        "[deleted news]"
    } if news["del"] && news["del"].to_i == 1
    
    domain = news_domain(news)
    # Extract text content BEFORE modifying the URL (only if needed)
    text_content = show_text ? news_text(news) : nil
    news = {}.merge(news) # Copy the object so we can modify it as we wish.
    news["url"] = "/news/#{news["id"]}" if !domain
    upclass = "uparrow"
    downclass = "downarrow"
    if news["voted"] == :up
        upclass << " voted"
        downclass << " disabled"
    elsif news["voted"] == :down
        downclass << " voted"
        upclass << " disabled"
    end
    H.article("data-news-id" => news["id"]) {
        H.a(:href => "#up", :class => upclass) {
            "&#9650;"
        }+" "+
        H.h2 {
            H.a(:href=>news["url"], :rel => "nofollow") {
                H.entities(news["title"] || "Untitled")
            }
        }+" "+
        H.address {
            if domain
                "("+H.entities(domain)+")"
            else "" end +
            if ($user and $user['id'].to_i == news['user_id'].to_i and
                news['ctime'].to_i > (Time.now.to_i - NewsEditTime))
                " " + H.a(:href => "/editnews/#{news["id"]}") {
                    "[edit]"
                }
            else "" end
        }+
        H.a(:href => "#down", :class =>  downclass) {
            "&#9660;"
        }+
        H.p {
            H.span(:class => :upvotes) { news["up"] } + " up and " +
            H.span(:class => :downvotes) { news["down"] } + " down, posted by " +            
            H.username {
                H.a(:href=>"/user/"+CGI.escape(news["username"])) {
                    H.entities news["username"]
                }
            }+" "+str_elapsed(news["ctime"].to_i)+" "+
            H.a(:href => "/news/#{news["id"]}") {
                comments_number = news["comments"].to_i
                if comments_number != 0
                    "#{comments_number} comment" + "#{'s' if comments_number>1}"
                else
                    "discuss"
                end
            }+
            if $user and user_is_admin?($user)
                " - "+H.a(:href => "/editnews/#{news["id"]}") { "edit" }
            else "" end
        }+
        (show_text && text_content ? H.div(:class => "newstext") {
            H.pre { H.entities(text_content) }
        } : "") +
        if params and params[:debug] and $user and user_is_admin?($user)
            "id: "+news["id"].to_s+" "+
            "score: "+news["score"].to_s+" "+
            "rank: "+compute_news_rank(news).to_s
        else "" end
    }+"\n"
end

# If 'news' is a list of news entries this function will render
# the HTML needed to show this news.
def news_list_to_html(news)
    H.section(:id => "newslist") {
        aux = ""
        news.each{|n|
            aux << news_to_html(n)
        }
        aux
    }
end

# Turn the news into its RSS representation
def news_to_rss(news)
    domain = news_domain(news)
    news = {}.merge(news) # Copy the object so we can modify it as we wish.
    news["ln_url"] = "#{SiteUrl}/news/#{news["id"]}"
    news["url"] = news["ln_url"] if !domain

    H.item {
        H.title {
            H.entities news["title"]
        } + " " +
        H.guid {
            H.entities news["url"]
        } + " " +
        H.link {
            H.entities news["url"]
        } + " " +
        H.description {
            "<![CDATA[" +
            H.a(:href=>news["ln_url"]) {
                "Comments"
            } + "]]>"
        } + " " +
        H.comments {
            H.entities news["ln_url"]
        }
    }+"\n"
end

# If 'news' is a list of news entries this function will render
# the RSS needed to show this news.
def news_list_to_rss(news)
    aux = ""
    news.each{|n|
        aux << news_to_rss(n)
    }
    aux
end

# Check that the list of parameters specified exist.
# If at least one is missing false is returned, otherwise true is returned.
#
# If a parameter is specified as as symbol only existence is tested.
# If it is specified as a string the parameter must also meet the condition
# of being a non empty string.
def check_params *required
    required.each{|p|
        params[p].strip! if params[p] and params[p].is_a? String
        if !params[p] or (p.is_a? String and params[p].length == 0)
            return false
        end
    }
    true
end

def check_api_secret
    return false if !$user
    params["apisecret"] and (params["apisecret"] == $user["apisecret"])
end

# Check if user has admin privileges
def user_is_admin?(user)
    return false if !user
    
    # Check admin flag in user flags field
    flags = user['flags'] || ''
    return true if flags.include?('a')
    
    # Fallback: check for admin usernames and user ID 1
    admin_usernames = ['admin', 'administrator']
    return true if admin_usernames.include?(user['username'].downcase) || user['id'].to_i == 1
    
    false
end

# Grant admin privileges to a user
def grant_admin_privileges(user_id)
    user = UserDB.get_user_by_id(user_id)
    return false if !user
    
    flags = user['flags'] || ''
    unless flags.include?('a')
        flags += 'a'
        UserDB.update_user_field(user_id, 'flags', flags)
    end
    true
end

# Remove admin privileges from a user
def revoke_admin_privileges(user_id)
    user = UserDB.get_user_by_id(user_id)
    return false if !user
    
    flags = user['flags'] || ''
    if flags.include?('a')
        flags = flags.gsub('a', '')
        UserDB.update_user_field(user_id, 'flags', flags)
    end
    true
end

# Generate CSRF token for forms
def generate_csrf_token
    SecureRandom.hex(32)
end

# Validate CSRF token
def validate_csrf_token(token)
    return false if !$user || !token
    # Simple token validation - in production you'd want to store and validate against session
    token.match?(/\A[a-f0-9]{64}\z/)
end

# Sanitize user input to prevent XSS
def sanitize_input(text)
    return "" if !text
    # Basic HTML entity encoding
    text.to_s.gsub(/[<>&"']/) { |m|
        case m
        when '<' then '&lt;'
        when '>' then '&gt;'
        when '&' then '&amp;'
        when '"' then '&quot;'
        when "'" then '&#39;'
        end
    }
end

# Authentication helper functions (SQLite versions)
def update_auth_token(user_id)
    new_token = SecureRandom.hex(20)
    UserDB.update_user_field(user_id, 'auth', new_token)
    new_token
end

# News helper functions (SQLite versions)
def render_news(news)
    H.div(:class => "news") {
        news_to_html(news, true)  # Show text content on individual news pages
    }
end

def comment_to_html(c, u, show_parent = false)
    return "[comment deleted]" if c['del'] && c['del'].to_i == 1
    
    indent = "margin-left:#{(c['level'] || 0).to_i * 20}px"
    username = u ? (u['username'] || 'deleted_user') : 'deleted_user'
    comment_id = c['id']
    news_id = c['thread_id'] || c['news_id']
    
    # Vote classes - match existing JavaScript expectations
    upclass = "uparrow"
    downclass = "downarrow"
    if c['up'] && $user && c['up'].include?($user['id'].to_i)
        upclass += " voted"
        downclass += " disabled"
    elsif c['down'] && $user && c['down'].include?($user['id'].to_i)
        downclass += " voted"
        upclass += " disabled"
    end
    
    # Use article tag to match existing JavaScript selector expectations
    H.article(:class => "comment", "data-comment-id" => "#{news_id}-#{comment_id}", :id => "comment-#{comment_id}", :style => indent) {
        H.div(:class => "comment-voting") {
            if $user
                H.a(:href => "#up", :class => upclass) {
                    "&#9650;"
                } + " " +
                H.a(:href => "#down", :class => downclass) {
                    "&#9660;"
                } + " "
            else
                ""
            end
        } +
        H.div(:class => "comment-content") {
            H.div(:class => "comment-meta") {
                "#{username} #{str_elapsed(c["ctime"].to_i)} ago" +
                " (#{(c['up'] && c['up'].length) || 0} up, #{(c['down'] && c['down'].length) || 0} down)"
            } +
            H.div(:class => "comment-body") {
                H.entities(c["body"] || "")
            } +
            H.div(:class => "comment-actions") {
                actions = []
                
                # Reply link
                if $user
                    actions << H.a(:href => "/reply/#{news_id}/#{comment_id}") {
                        "reply"
                    }
                end
                
                # Edit/Delete links for comment owner
                if $user && $user['id'].to_i == c['user_id'].to_i
                    actions << H.a(:href => "/editcomment/#{news_id}/#{comment_id}") {
                        "edit"
                    }
                end
                
                actions.join(" | ")
            }
        }
    }
end

def render_comments_for_news(news_id, root=-1)
    html = ""
    user = {}
    Comments.render_comments(news_id, root) {|c|
        user[c["id"]] = UserDB.get_user_by_id(c["user_id"]) if !user[c["id"]]
        user[c["id"]] = {"username" => "deleted_user"} if !user[c["id"]]
        u = user[c["id"]]
        html << comment_to_html(c, u)
    }
    html
end

def render_comment_subthread(comment, sep="")
    H.div(:class => "singlecomment") {
        u = UserDB.get_user_by_id(comment["user_id"])
        comment_to_html(comment, u, true)
    }+H.div(:class => "commentreplies") {
        sep+
        render_comments_for_news(comment['thread_id'], comment["id"].to_i)
    }
end

def render_comment_form_for_news(news_id)
    return "" if !$user  # Only show form to logged-in users
    
    H.div(:id => "comment-form", :class => "comment-form") {
        H.h3 {"Add Comment"} +
        H.form(:name => "f") {
            H.inputhidden(:name => "news_id", :value => news_id) +
            H.inputhidden(:name => "comment_id", :value => -1) +
            H.inputhidden(:name => "parent_id", :value => -1) +
            H.textarea(:name => "comment", :cols => 60, :rows => 6, :placeholder => "Write your comment here...") {} +
            H.br +
            H.button(:name => "post_comment", :value => "Post Comment") 
        } +
        H.div(:id => "errormsg"){}
    } +
    H.script() {'
        $(function() {
            $("input[name=post_comment]").click(post_comment);
        });
    '}
end

# Essential API endpoints for AJAX functionality
get '/api/login' do
    content_type 'application/json'
    if (!check_params "username","password")
        return {
            :status => "err",
            :error => "Username and password are two required fields."
        }.to_json
    end
    auth,apisecret = check_user_credentials(params[:username],
                                            params[:password])
    if auth 
        return {
            :status => "ok",
            :auth => auth,
            :apisecret => apisecret
        }.to_json
    else
        return {
            :status => "err",
            :error => "Login failed. Check your username and password."
        }.to_json
    end
end

post '/api/submit' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end

    # Check that we have a title
    if !check_params("title")
        return {
            :status => "err",
            :error => "Missing required fields (title)."
        }.to_json
    end
    
    # Validate title length
    if params[:title].length > 256
        return {
            :status => "err",
            :error => "Title too long (maximum 256 characters)."
        }.to_json
    end
    
    if params[:title].strip.empty?
        return {
            :status => "err",
            :error => "Title cannot be empty."
        }.to_json
    end
    
    # Ensure we have url and text params (even if empty)
    params[:url] = "" if !params[:url]
    params[:text] = "" if !params[:text]
    
    # Validate text length for text posts
    if params[:text].length > 8192
        return {
            :status => "err",
            :error => "Text too long (maximum 8192 characters)."
        }.to_json
    end
    
    # Default news_id to -1 for new submissions if not provided
    params[:news_id] = "-1" if !params[:news_id] || params[:news_id].strip.empty?
    
    if params[:url].length == 0 and params[:text].length == 0
        return {
            :status => "err",
            :error => "Please specify a news title and address or text."
        }.to_json
    end
    # Make sure the URL is about an acceptable protocol, that is
    # http:// or https:// for now.
    if params[:url].length != 0
        if params[:url].index("http://") != 0 and
           params[:url].index("https://") != 0
            return {
                :status => "err",
                :error => "We only accept http:// and https:// news."
            }.to_json
        end
    end
    if params[:news_id].to_i == -1
        if submitted_recently
            return {
                :status => "err",
                :error => "You have submitted a story too recently, "+
                "please wait #{allowed_to_post_in_seconds} seconds."
            }.to_json
        end
        news_id = insert_news(params[:title],params[:url],params[:text],
                              $user["id"])
    else
        # Rate limit news editing operations
        if rate_limit_by_ip(30, "edit_news", request.ip)
            return {
                :status => "err",
                :error => "Too many edit operations. Please wait a moment."
            }.to_json
        end
        
        news_id = edit_news(params[:news_id],params[:title],params[:url],
                            params[:text],$user["id"])
        if !news_id
            return {
                :status => "err",
                :error => "Invalid parameters, news too old to be modified "+
                          "or url recently posted."
            }.to_json
        end
    end
    return  {
        :status => "ok",
        :news_id => news_id.to_i
    }.to_json
end

post '/api/votenews' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    return {:status => "err", :error => "Missing API secret."}.to_json if !check_api_secret
    return {:status => "err", :error => "Missing required fields."}.to_json if !check_params("news_id","vote_type")
    
    news_id = params[:news_id].to_i
    vote_type = params[:vote_type]
    
    if VoteDB.cast_vote($user['id'], 'news', news_id, vote_type)
        return {:status => "ok", :news_id => news_id}.to_json
    else
        return {:status => "err", :error => "You have already voted on this news item."}.to_json
    end
end

post '/api/postcomment' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    return {:status => "err", :error => "Missing API secret."}.to_json if !check_api_secret
    return {:status => "err", :error => "Missing required fields."}.to_json if !check_params("news_id","comment")
    
    news_id = params[:news_id].to_i
    comment_text = params[:comment]
    parent_id = params[:parent_id] ? params[:parent_id].to_i : -1
    comment_id = params[:comment_id] ? params[:comment_id].to_i : -1
    
    # Check if this is an edit operation
    if comment_id != -1
        # Editing existing comment
        existing_comment = Comments.fetch(news_id, comment_id)
        return {:status => "err", :error => "Comment not found."}.to_json if !existing_comment
        return {:status => "err", :error => "Permission denied."}.to_json if existing_comment['user_id'].to_i != $user['id'].to_i
        
        # If comment is empty, delete it (as mentioned in the edit form note)
        if comment_text.strip.empty?
            if Comments.del_comment(news_id, comment_id)
                return {:status => "ok", :op => "delete", :news_id => news_id, :comment_id => comment_id}.to_json
            else
                return {:status => "err", :error => "Error deleting comment."}.to_json
            end
        end
        
        # Update comment
        if Comments.edit(news_id, comment_id, {'body' => comment_text})
            return {:status => "ok", :op => "update", :news_id => news_id, :comment_id => comment_id}.to_json
        else
            return {:status => "err", :error => "Error updating comment."}.to_json
        end
    else
        # Creating new comment
        if comment_text.length < 2
            return {:status => "err", :error => "Comment must be at least 2 characters long."}.to_json
        end
        
        comment_data = {
            'parent_id' => parent_id,
            'user_id' => $user['id'],
            'body' => comment_text
        }
        
        new_comment_id = Comments.insert(news_id, comment_data)
        if new_comment_id
            return {:status => "ok", :op => "insert", :news_id => news_id, :comment_id => new_comment_id}.to_json
        else
            return {:status => "err", :error => "Error posting comment."}.to_json
        end
    end
end

# User account creation API
post '/api/create_account' do
    content_type 'application/json'
    
    if (!check_params "username","password")
        return {
            :status => "err",
            :error => "Username and password are two required fields."
        }.to_json
    end
    
    if !params[:username].match(UsernameRegexp)
        return {
            :status => "err", 
            :error => "Username must match /#{UsernameRegexp.source}/"
        }.to_json
    end
    
    if params[:password].length < PasswordMinLength
        return {
            :status => "err",
            :error => "Password is too short. Min length: #{PasswordMinLength}"
        }.to_json
    end
    
    # Check if user already exists
    if UserDB.get_user_by_username(params[:username])
        return {
            :status => "err",
            :error => "Username already exists."
        }.to_json
    end
    
    # Validate email if provided
    email = params[:email] || ""
    if email.length > 0 && !is_valid_email?(email)
        return {
            :status => "err",
            :error => "Invalid email address format."
        }.to_json
    end

    # Hash the password before storing
    password_hash = BCrypt::Password.create(params[:password], cost: BCryptCost)
    
    begin
        auth, apisecret, user_id = UserDB.create_user(params[:username], password_hash, email)
        if auth
            return {
                :status => "ok", 
                :auth => auth, 
                :apisecret => apisecret
            }.to_json
        else
            return {
                :status => "err",
                :error => "Failed to create account."
            }.to_json
        end
    rescue => e
        return {
            :status => "err",
            :error => "Username already exists."
        }.to_json
    end
end

# User logout API  
post '/api/logout' do
    content_type 'application/json'
    
    if $user and check_api_secret
        # Generate new auth token to invalidate current session
        new_auth = SecureRandom.hex(16)
        Database.execute("UPDATE users SET auth = ? WHERE id = ?", [new_auth, $user['id']])
        return {:status => "ok"}.to_json
    else
        return {
            :status => "err",
            :error => "Wrong auth credentials or API secret."
        }.to_json
    end
end

# Password reset request API
post '/api/reset-password' do
    content_type 'application/json'
    
    if (!check_params "username","email")
        return {
            :status => "err",
            :error => "Username and email are two required fields."
        }.to_json
    end

    user = UserDB.get_user_by_username(params[:username])
    if user && user['email'] && user['email'] == params[:email]
        # Check rate limiting
        if (user['pwd_reset'] && 
            (Time.now.to_i - user['pwd_reset'].to_i) < PasswordResetDelay)
            return {
                :status => "err",
                :error => "Sorry, not enough time elapsed since last password reset request."
            }.to_json
        end

        # Generate reset token and save it
        reset_token = generate_password_reset_token(user['id'])
        Database.execute("UPDATE users SET pwd_reset = ? WHERE id = ?", 
                        [Time.now.to_i, user['id']])
        
        # Send email to terminal for testing
        puts "\n🔄 Attempting to send password reset email to terminal..."
        send_reset_password_email(user, reset_token)
        puts "✅ Password reset email sent to terminal output\n"
        
        return {:status => "ok"}.to_json
    else
        return {
            :status => "err", 
            :error => "No match for the specified username / email pair."
        }.to_json
    end
end

# Set new password API
post '/api/set-new-password' do
    content_type 'application/json'
    
    if (!check_params "token","password")
        return {
            :status => "err",
            :error => "Token and password are required fields."
        }.to_json
    end
    
    if params[:password].length < PasswordMinLength
        return {
            :status => "err",
            :error => "Password is too short. Min length: #{PasswordMinLength}"
        }.to_json
    end

    # Validate the reset token
    token_data = TokenDB.get_password_reset_token(params[:token])
    if !token_data
        return {
            :status => "err",
            :error => "Invalid or expired reset token."
        }.to_json
    end

    # Get the user associated with this token
    user = UserDB.get_user_by_id(token_data['user_id'])
    if !user
        return {
            :status => "err", 
            :error => "User account not found."
        }.to_json
    end

    begin
        Database.transaction do
            # Update the user's password
            password_hash = BCrypt::Password.create(params[:password], cost: BCryptCost)
            Database.execute("UPDATE users SET password = ? WHERE id = ?",
                            [password_hash, user['id']])
            
            # Mark the token as used
            TokenDB.use_password_reset_token(params[:token])
            
            # Generate new auth token to invalidate existing sessions
            new_auth = SecureRandom.hex(16)
            new_apisecret = SecureRandom.hex(16)
            Database.execute("UPDATE users SET auth = ?, apisecret = ? WHERE id = ?",
                            [new_auth, new_apisecret, user['id']])
        end

        puts "\n🔒 PASSWORD RESET SUCCESSFUL for user: #{user['username']}"
        
        return {
            :status => "ok", 
            :message => "Password updated successfully. Please login with your new password."
        }.to_json
    rescue => e
        return {
            :status => "err",
            :error => "Failed to update password: #{e.message}"
        }.to_json
    end
end

# News deletion API
post '/api/delnews' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    return {:status => "err", :error => "Wrong form secret."}.to_json if !check_api_secret
    
    # Rate limit news deletion operations
    if rate_limit_by_ip(60, "delete_news", request.ip)
        return {
            :status => "err",
            :error => "Too many delete operations. Please wait a moment."
        }.to_json
    end
    
    if (!check_params "news_id")
        return {
            :status => "err",
            :error => "Please specify a news ID."
        }.to_json
    end
    
    news_id = params[:news_id].to_i
    news = NewsDB.get_news_by_id(news_id)
    
    if !news
        return {:status => "err", :error => "News not found."}.to_json
    end
    
    # Check ownership or admin status
    if news['user_id'].to_i != $user['id'].to_i && !user_is_admin?($user)
        return {:status => "err", :error => "Permission denied."}.to_json
    end
    
    # Mark as deleted
    NewsDB.update_news_field(news_id, 'del', 1)
    return {:status => "ok", :news_id => news_id}.to_json
end

# Comment voting API
post '/api/votecomment' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    return {:status => "err", :error => "Wrong form secret."}.to_json if !check_api_secret
    
    # Params sanity check
    if (!check_params "comment_id","vote_type") or
                                            (params["vote_type"] != "up" and
                                             params["vote_type"] != "down")
        return {
            :status => "err",
            :error => "Missing comment ID or invalid vote type."
        }.to_json
    end
    
    # Parse comment ID (format: news_id-comment_id)
    vote_type_str = params["vote_type"]
    news_id, comment_id = params["comment_id"].split("-")
    
    # Ensure we have both parts of the comment ID
    if news_id.nil? || comment_id.nil? || comment_id.to_i == 0
        return {
            :status => "err",
            :error => "Invalid comment ID format. Expected format: news_id-comment_id"
        }.to_json
    end
    
    user_id = $user["id"]
    comment_id_int = comment_id.to_i
    
    # Use the standard VoteDB.cast_vote method
    if VoteDB.cast_vote(user_id, 'comment', comment_id_int, vote_type_str)
        return { :status => "ok", :comment_id => params["comment_id"] }.to_json
    else
        return { :status => "err", :error => "You have already voted on this comment." }.to_json
    end
end

# Update user profile API
post '/api/updateprofile' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    return {:status => "err", :error => "Wrong form secret."}.to_json if !check_api_secret
    
    email = params[:email] || ""
    about = params[:about] || ""
    password = params[:password]
    
    # Validate email if provided
    if email.length > 0 && !is_valid_email?(email)
        return {
            :status => "err",
            :error => "Invalid email address format."
        }.to_json
    end
    
    # Validate password if provided
    if password && password.length > 0 && password.length < PasswordMinLength
        return {
            :status => "err", 
            :error => "Password is too short. Min length: #{PasswordMinLength}"
        }.to_json
    end
    
    Database.transaction do
        # Update email and about
        Database.execute("UPDATE users SET email = ?, about = ? WHERE id = ?",
                        [email, about, $user['id']])
        
        # Update password if provided
        if password && password.length > 0
            hashed_password = BCrypt::Password.create(password, cost: BCryptCost)
            Database.execute("UPDATE users SET password = ? WHERE id = ?",
                            [hashed_password, $user['id']])
        end
    end
    
    return {:status => "ok"}.to_json
rescue => e
    return {
        :status => "err",
        :error => "Failed to update profile: #{e.message}"
    }.to_json
end



# Edit news page
get "/editnews/:news_id" do
    redirect "/login" unless $user
    news = get_news_by_id(params["news_id"])
    halt(404, "404 - This news does not exist.") unless news
    halt(500, "Permission denied.") unless $user['id'].to_i == news['user_id'].to_i || user_is_admin?($user)

    if news_domain(news)
        text = ""
    else
        text = news_text(news)
        news['url'] = ""
    end
    
    H.set_title "Edit news - #{SiteName}"
    H.page {
        news_to_html(news) +
        H.div(:id => "submitform") {
            H.form(:name => "f") {
                H.inputhidden(:name => "news_id", :value => news['id']) +
                H.label(:for => "title") { "title" } +
                H.inputtext(:id => "title", :name => "title", :size => 80,
                            :value => news['title'] || "") + H.br +
                H.label(:for => "url") { "url" } + H.br +
                H.inputtext(:id => "url", :name => "url", :size => 60,
                            :value => H.entities(news['url'])) + H.br +
                "or if you don't have an url type some text" +
                H.br +
                H.label(:for => "text") { "text" } +
                H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {
                    H.entities(text)
                } + H.br +
                H.checkbox(:name => "del", :value => "1") +
                "delete this news" + H.br +
                H.button(:name => "edit_news", :value => "Edit")
            }
        } +
        H.div(:id => "errormsg") {} +
        H.script() { '
            $(function() {
                $("input[name=edit_news]").click(submit);
            });
        ' }
    }
end

################################################################################
# Admin Functions
################################################################################

# Generate site statistics for admin panel
def generate_site_stats
    begin
        # Use simpler queries that match existing patterns in the codebase
        result = Database.execute("SELECT COUNT(*) FROM users")
        users_count = result[0][0] || 0
        
        result = Database.execute("SELECT COUNT(*) FROM news")
        news_count = result[0][0] || 0
        
        result = Database.execute("SELECT COUNT(*) FROM comments")
        comments_count = result[0][0] || 0
        
        # Count deleted items
        deleted_news = Database.execute("SELECT COUNT(*) FROM news WHERE del = 1")[0][0] || 0
        deleted_comments = Database.execute("SELECT COUNT(*) FROM comments WHERE del = 1")[0][0] || 0
        
        # Count admins 
        admins_count = Database.execute("SELECT COUNT(*) FROM users WHERE flags LIKE '%a%'")[0][0] || 0
        
        # Active (non-deleted) counts
        active_news = news_count - deleted_news
        active_comments = comments_count - deleted_comments
        
        # Recent activity (last 24 hours) - simplified
        yesterday = Time.now.to_i - 86400
        recent_users = Database.execute("SELECT COUNT(*) FROM users WHERE ctime > ?", yesterday)[0][0] || 0
        recent_news = Database.execute("SELECT COUNT(*) FROM news WHERE ctime > ?", yesterday)[0][0] || 0
        recent_comments = Database.execute("SELECT COUNT(*) FROM comments WHERE ctime > ?", yesterday)[0][0] || 0
        
        # Database size
        db_size_kb = File.size(Database.db_path) / 1024
        
        H.ul {
            H.li {"#{users_count} total users (#{admins_count} admins)"} +
            H.li {"#{active_news} active news items (#{deleted_news} deleted)"} +
            H.li {"#{active_comments} active comments (#{deleted_comments} deleted)"} +
            H.li {"SQLite database size: #{db_size_kb} KB"} +
            H.li {"Last 24h activity: #{recent_users} new users, #{recent_news} news, #{recent_comments} comments"}
        }
    rescue => e
        H.ul {
            H.li {"Error loading statistics: #{e.message}"} +
            H.li {"Database path: #{Database.db_path}"}
        }
    end
end

# Compute news score based on votes (SQLite version)
def compute_news_score(news)
    news_id = news['id']
    upvotes = Database.execute("SELECT COUNT(*) FROM votes WHERE news_id = ? AND type = 'up'", news_id)[0][0] || 0
    downvotes = Database.execute("SELECT COUNT(*) FROM votes WHERE news_id = ? AND type = 'down'", news_id)[0][0] || 0
    
    # Basic score calculation: upvotes minus downvotes
    score = upvotes - downvotes
    
    # Add logarithmic boost for high-activity posts
    total_votes = upvotes + downvotes
    if total_votes > NewsScoreLogStart
        score += Math.log(total_votes - NewsScoreLogStart) * NewsScoreLogBooster
    end
    
    score
end

# Compute news rank based on time and score (SQLite version)
def compute_news_rank(news)
    age = (Time.now.to_i - news['ctime'].to_i)
    score = news['score'].to_f
    rank = (score * 1000000) / ((age + NewsAgePadding) ** RankAgingFactor)
    rank = -age if (age > TopNewsAgeLimit)
    return rank
end