--[==[

	webb | cookie/db-based session & authentication module
	Written by Cosmin Apreutesei. Public Domain.

SESSIONS

	login([auth][, switch_user]) -> uid       login
	logout() -> uid                           logout and get an anonymous uid
	uid([field|'*']) -> val | t | uid         get current user field(s) or id
	admin() -> t|f                            user has admin rights
	touch_usr()                               update user's atime
	set_pass([uid, ]pass)                     set password for (current) user
	send_auth_token(email, lang)              send auth token by email

CONFIG

	config('session_secret')                  for encrypting session cookies
	config('pass_salt')                       for encrypting passwords in db

	config('pass_token_lifetime', 3600)       forgot-password token lifetime
	config('pass_token_maxcount', 2)          max unexpired tokens allowed
	config('no_reply_email', email'no-reply') sender for send_auth_token()

	S('reset_pass_subject')                   subject for send_auth_token()

	template.reset_pass_email                 template for send_auth_token()

	action['session_instal.txt']              (re)create usr & session tables
	action['login.json']                      login() server-side

API DOCS

	uid() -> uid

Get the current user id. Same as calling `login()` without args but
caches the uid so it can be called multiple times without actually
performing the login.

	uid(field) -> v

Get the value of a a specific field from the user info.

	uid'*' -> t

Get full user info.

	logout() -> uid

Clears the session cookie and creates an anonymous user and returns it.

	admin() -> t|f

Returns true if the user has the admin flag.

	touch_usr()

Update user's access time. Call it on every request as a way of tracking
user activity, eg. for knowing when to send those annoying "forgot items
in your cart" emails.

AUTH OBJECT

	{type = 'session'}

login using session cookie (default). if there's no session cookie
or it's invalid, an anonymous user is created.

	{type = 'anonymous'}

login using session cookie but logout and create an anonymous user
if the logged in user is not anonymous.

	{type = 'pass', action = 'login', email = , pass = }

login to an existing user using its email and password. returns
`nil, 'user_pass'` if the email or password is wrong.

	{type = 'pass', action = 'create', email = , pass = }

create a user and login to it. returns `nil, 'email_taken'` if the email is
already taken. the admin flag is set for the first non-anonymous user to be
created.

	{type = 'nopass', email = }

login using only user.

	{type = 'update', email = , name = ', phone = }

update the info of the currently logged in user. an attempt to change the
email to the email of a different user results in `nil, 'email_taken'`.

	{type = 'token', token = }

login using a temporary token that was generated by the remember password
form. a token can be used only once. returns `nil, 'invalid_token'` if the
token was not found or expired.

	{type = 'facebook', access_token = }

login using facebook authentication. user's fields `email`, `facebookid`,
`name`, and `gender` are also updated.

	{type = 'google', access_token = }

login using google+ authentication. user's fields `email`, `googleid`,
`gimgurl` and `name` are also updated.

NOTE: Regardless of how the user is authenticated, the session cookie is
updated and it will be sent with the reply. If there was already a user
logged in before and it was a different user, the callback
`switch_user(new_uid, old_uid)` is called. If that previous user was
anonymous then that user is also deleted afterwards.

]==]

local random_string = require'resty.random'
local session = require'session'

require'query'

local function fullname(firstname, lastname)
	return glue.trim((firstname or '')..' '..(lastname or ''))
end

--session cookie -------------------------------------------------------------

local session = once(function()
	session.cookie.persistent = true
	session.check.ssi = false --ssi will change after browser closes
	session.check.ua = false  --user could upgrade the browser
	session.cookie.lifetime = 2 * 365 * 24 * 3600 --2 years
	session.secret = config'session_secret'
	return assert(session.start())
end)

local function session_uid()
	return session().data.uid
end

local clear_uid_cache --fw. decl

local function save_uid(uid)
	local session = session()
	if uid ~= session.data.uid then
		session.data.uid = uid
		session:save()
		clear_uid_cache()
	end
end

--authentication frontend ----------------------------------------------------

local auth = {} --auth.<type>(auth) -> uid, can_create

local function authenticate(a)
	return auth[a and a.type or 'session'](a)
end

local function userinfo(uid)
	if not uid then return {} end
	local t = query1([[
		select
			uid,
			email,
			anonymous,
			emailvalid,
			if(pass is not null, 1, 0) as haspass,
			googleid,
			facebookid,
			admin,
			--extra non-functional fields
			name,
			phone,
			gimgurl
		from
			usr
		where
			active = 1 and uid = ?
		]], uid)
	if not t then return {} end
	t.anonymous = t.anonymous == 1
	t.emailvalid = t.emailvalid == 1
	t.haspass = tonumber(t.haspass) == 1
	t.admin = t.admin == 1
	return t
end

local function clear_userinfo_cache(uid)
	once(userinfo, true, uid)
end

local userinfo = once(userinfo)

--session-cookie authentication ----------------------------------------------

local function valid_uid(uid)
	return userinfo(uid).uid
end

local function anonymous_uid(uid)
	return userinfo(uid).anonymous and uid
end

local function create_user()
	ngx.sleep(0.2) --make filling it up a bit harder
	return iquery([[
		insert into usr
			(clientip, atime, ctime, mtime)
		values
			(?, now(), now(), now())
	]], client_ip())
end

function auth.session()
	return valid_uid(session_uid()) or create_user()
end

--anonymous authentication ---------------------------------------------------

function auth.anonymous()
	return anonymous_uid(session_uid()) or create_user()
end

--password authentication ----------------------------------------------------

local function salted_hash(token, salt)
	token = ngx.hmac_sha1(assert(salt), assert(token))
	return glue.tohex(token) --40 bytes
end

local function pass_hash(pass)
	return salted_hash(pass, config'pass_salt')
end

local function pass_uid(email, pass)
	ngx.sleep(0.2) --slow down brute-forcing
	return query1([[
		select uid from usr where
			active = 1 and email = ? and pass = ?
		]], email, pass_hash(pass))
end

local function pass_email_uid(email)
	return query1([[
		select uid from usr where
			active = 1 and pass is not null and email = ?
		]], email)
end

local function delete_user(uid)
	query('delete from usr where uid = ?', uid)
end

--no-password authentication: use only for debugging!
function auth.nopass(auth)
	return pass_email_uid(auth.email)
end

function auth.pass(auth)
	if auth.action == 'login' then
		local uid = pass_uid(auth.email, auth.pass)
		if not uid then
			return nil, 'user_pass'
		else
			return uid
		end
	elseif auth.action == 'create' then
		local email = glue.trim(assert(auth.email))
		assert(#email >= 1)
		local pass = assert(auth.pass)
		assert(#pass >= 1)
		if pass_email_uid(email) then
			return nil, 'email_taken'
		end
		local uid = anonymous_uid(session_uid()) or create_user()
		--first non-anonymous user to be created is made admin
		local admin = tonumber(query1([[
			select count(1) from usr where anonymous = 0
			]])) == 0
		query([[
			update usr set
				anonymous = 0,
				emailvalid = 0,
				email = ?,
				pass = ?,
				admin = ?
			where
				uid = ?
			]], email, pass_hash(pass), admin, uid)
		clear_userinfo_cache(uid)
		return uid
	end
end

function set_pass(uid, pass)
	if not pass then
		uid, pass = nil, uid
	end
	if not uid then
		local usr = userinfo(allow(session_uid()))
		allow(usr.uid)
		allow(usr.haspass)
		uid = usr.uid
	end
	query('update usr set pass = ? where uid = ?', pass_hash(pass), uid)
	clear_userinfo_cache(uid)
end

--update info (not really auth, but related) ---------------------------------

function auth.update(auth)
	local uid = allow(session_uid())
	local usr = userinfo(uid)
	allow(usr.uid)
	local email = glue.trim(assert(auth.email))
	local name = glue.trim(assert(auth.name))
	local phone = glue.trim(assert(auth.phone))
	assert(#email >= 1)
	if usr.haspass then
		local euid = pass_email_uid(email)
		if euid and euid ~= uid then
			return nil, 'email_taken'
		end
	end
	query([[
		update usr set
			email = ?,
			name = ?,
			phone = ?,
			emailvalid = if(email <> ?, 0, emailvalid)
		where
			uid = ?
		]], email, name, phone, email, uid)
	clear_userinfo_cache(uid)
	return uid
end

--one-time token authentication ----------------------------------------------

local token_lifetime = config('pass_token_lifetime', 3600)

local function gen_token(uid)

	--now it's a good time to garbage-collect expired tokens
	query('delete from usrtoken where ctime < now() - ?', token_lifetime)

	--check if too many tokens were requested
	local n = query1([[
		select count(1) from usrtoken where
			uid = ? and ctime > now() - ?
		]], uid, token_lifetime)
	if tonumber(n) >= config('pass_token_maxcount', 2) then
		return
	end

	local token = pass_hash(random_string(32))

	--add the token to db (break on collisions)
	query([[
		insert into usrtoken
			(token, uid, ctime)
		values
			(?, ?, now())
		]], pass_hash(token), uid)

	return token
end

function send_auth_token(email, lang)
	--find the user with this email
	local uid = pass_email_uid(email)
	if not uid then return end --hide the error for privacy

	--generate a new token for this user if we can
	local token = gen_token(uid)
	if not token then return end --hide the error for privacy

	--send it to the user
	local subj = S('reset_pass_subject', 'Your reset password link')
	local msg = filter_lang(render('reset_pass_email', {
		url = absurl('/login/'..token),
	}), lang)
	local from = config'noreply_email' or email'no-reply'
	sendmail(from, email, subj, msg)
end

template['reset_pass_email'] = [[

Click on the link below to reset your password:

{{url}}
]]

local function token_uid(token)
	ngx.sleep(0.2) --slow down brute-forcing
	return query1([[
		select uid from usrtoken where token = ? and ctime > now() - ?
		]], pass_hash(token), token_lifetime)
end

function auth.token(auth)
	--find the user
	local uid = token_uid(auth.token)
	if not uid then return nil, 'invalid_token' end

	--remove the token because it's single use, and also to allow
	--the user to keep forgetting his password as much as he wants.
	query('delete from usrtoken where token = ?', pass_hash(auth.token))

	return uid
end

--facebook authentication ----------------------------------------------------

local function facebook_uid(facebookid)
	return query1('select uid from usr where facebookid = ?', facebookid)
end

local function facebook_graph_request(url, args)
	local res = ngx.location.capture('/graph.facebook.com'..url, {args = args})
	if res and res.status == 200 then
		local t = json(res.body)
		if t and not t.error then
			return t
		end
	end
	ngx.log(ngx.ERR, 'facebook_graph_request: ', url, ' ',
		pp.format(args, ' '), ' -> ', pp.format(res, ' '))
end

function auth.facebook(auth)
	--get info from facebook
	local t = facebook_graph_request('/v2.1/me',
		{access_token = auth.access_token})
	if not t then return end

	--grab a uid
	local uid =
		facebook_uid(t.id)
		or anonymous_uid(session_uid())
		or create_user()

	--deanonimize user and update its info
	query([[
		update usr set
			anonymous = 0,
			emailvalid = 1,
			email = ?,
			facebookid = ?,
			name = ?,
			gender = ?
		where
			uid = ?
		]], t.email, t.id, fullname(t.first_name, t.last_name), t.gender, uid)
	clear_userinfo_cache(uid)

	return uid
end

--google+ authentication -----------------------------------------------------

local function google_uid(googleid)
	return query1('select uid from usr where googleid = ?', googleid)
end

local function google_api_request(url, args)
	local res = ngx.location.capture('/content.googleapis.com'..url, {args = args})
	if res and res.status == 200 then
		return json(res.body)
	end
	ngx.log(ngx.ERR, 'google_api_request: ', url, ' ',
		pp.format(args, ' '), ' -> ', pp.format(res, ' '))
end

function auth.google(auth)
	--get info from google
	local t = google_api_request('/plus/v1/people/me',
		{access_token = auth.access_token})
	if not t then return end

	--grab a uid
	local uid =
		google_uid(t.id)
		or anonymous_uid(session_uid())
		or create_user()

	--deanonimize user and update its info
	query([[
		update usr set
			anonymous = 0,
			emailvalid = 1,
			email = ?,
			googleid = ?,
			gimgurl = ?,
			name = ?
		where
			uid = ?
		]],
		t.emails and t.emails[1] and t.emails[1].value,
		t.id,
		t.image and t.image.url,
		t.name and fullname(t.name.givenName, t.name.familyName),
		uid)
	clear_userinfo_cache(uid)

	return uid
end

--authentication logic -------------------------------------------------------

function login(auth, switch_user)
	switch_user = switch_user or glue.pass
	local uid, err = authenticate(auth)
	local suid = valid_uid(session_uid())
	if uid then
		if uid ~= suid then
			if suid then
				switch_user(suid, uid)
				if anonymous_uid(suid) then
					delete_user(suid)
				end
			end
			save_uid(uid)
		end
	end
	return uid, err
end

uid = once(function(attr)
	local uid = login()
	if attr == '*' then
		return userinfo(uid)
	elseif attr then
		return userinfo(uid)[attr]
	else
		return uid
	end
end)

function clear_uid_cache() --local, fw. declared
	once(uid, true)
end

function logout()
	save_uid(nil)
	return authenticate()
end

function admin()
	return userinfo(uid()).admin
end

function touch_usr()
	--only touch usr on page requests
	if args(1):find'%.' and not args(1):find'%.html$' then
		return
	end
	local uid = session_uid()
	if not uid then return end
	query([[
		update usr set
			atime = now(), mtime = mtime
		where uid = ?
	]], uid)
end

--install --------------------------------------------------------------------

action['session_install.txt'] = function()

	droptable'usrtoken'
	droptable'usr'

	print_queries(true)

	query[[
	$table usr (
		uid         $pk,
		anonymous   $bool1,
		email       $email,
		emailvalid  $bool,
		pass        $hash,
		facebookid  $name,
		googleid    $name,
		gimgurl     $url,  --google image url
		active      $bool1,
		name        $name,
		phone       $name,
		gender      $name,
		birthday    date,
		newsletter  $bool,
		admin       $bool,
		note        text,
		clientip    $name, --when it was created
		atime       $atime, --last access time
		ctime       $ctime, --creation time
		mtime       $mtime  --last modification time
	);
	]]

	query[[
	$table usrtoken (
		token       $hash not null primary key,
		uid         $id not null, $fk(usrtoken, uid, usr),
		ctime       $ctime
	);
	]]

end

action['login.json'] = function(...)
	if ... == 'logout' then
		allow(logout())
	else
		local auth = post()
		allow(login(auth))
	end

	return uid'*'
end
