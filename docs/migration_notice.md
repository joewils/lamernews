# Password Security Migration Notice

## Important: Password Reset Required

Due to a security upgrade from PBKDF2 to bcrypt password hashing, all existing users will need to reset their passwords.

### For Users:
1. Visit the login page
2. Click "reset password" 
3. Enter your username and email address
4. Check your email for the reset link
5. Set a new password

### For Administrators:
- New user registrations automatically use bcrypt
- Password changes by existing users will upgrade to bcrypt
- Legacy PBKDF2 hashes are no longer accepted for security reasons

### Technical Details:
- bcrypt provides better security than PBKDF2
- Cost factor set to 12 for good security/performance balance
- All new passwords are automatically salted by bcrypt
- Migration is one-way (cannot downgrade)

### Files Modified:
- `Gemfile`: Added bcrypt gem
- `app_config.rb`: Added BCryptCost configuration
- `app.rb`: Updated hash_password and check_user_credentials functions
- Removed dependency on `pbkdf2.rb`