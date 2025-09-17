get '/about' do
    H.set_title "About - #{SiteName}"
    H.page {
        H.div(:id => "about") {
            H.h2 {"#{SiteName}"}+
            H.p {"Lamer news is an implementation of a Reddit / Hacker News style news web site written using Ruby, Sinatra, SQLite and jQuery."}+
            H.p {"The goal is to have a system that is very simple to understand and modify and that is able to handle a very high load using a small virtual server, ensuring at the same time a very low latency user experience."}+
            H.p {"This project was created in order to run " + H.a(:href => "http://lamernews.com/") {"Lamer News"} + " but is free for everybody to use, fork, and have fun with."}+
            H.p {"This version uses SQLite as the database, providing ACID compliance and simplified deployment while maintaining all the original functionality."}
        }
    }
end