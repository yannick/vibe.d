﻿module vibe.stream.botan;

version(Botan):
version = X509;
import botan.constants;
import botan.cert.x509.x509cert;
import botan.cert.x509.certstor;
import botan.cert.x509.x509path;
import botan.tls.blocking;
import botan.tls.channel;
import botan.tls.credentials_manager;
import botan.tls.server;
import botan.tls.session_manager;
import botan.tls.server_info;
import botan.tls.ciphersuite;
import botan.rng.auto_rng;
import vibe.core.stream;
import vibe.stream.tls;
import vibe.core.net;
import std.datetime;
import std.exception;

class BotanTLSStream : TLSStream, Buffered
{
private:
	TCPConnection m_tcp_conn;
	// todo: UDPConnection m_udp_conn;
	TLSBlockingChannel m_tls_channel;
	BotanTLSContext m_ctx;

	void* m_userData;
	OnAlert m_alert_cb;
	OnHandshakeComplete m_handshake_complete;
	TLSCiphersuite m_cipher;
	TLSProtocolVersion m_ver;
	SysTime m_session_age;
	X509Certificate m_peer_cert;
	TLSCertificateInformation m_cert_compat;
	ubyte[] m_sess_id;
	Exception m_ex;

public:
	/// Returns the date/time the session was started
	@property SysTime started() const { return m_session_age; }

	/// Get the session ID
	@property const(ubyte[]) sessionId() { return m_sess_id; } 

	/// Returns the remote public certificate from the chain
	@property const(X509Certificate) x509Certificate() const { return m_peer_cert; }

	/// Returns the negotiated version of the TLS Protocol
	@property TLSProtocolVersion protocol() const { return m_ver; }

	/// Returns the complete ciphersuite details from the negotiated TLS connection
	@property TLSCiphersuite cipher() const { return m_cipher; }

	@property string alpn() const { return m_tls_channel.underlyingChannel().applicationProtocol(); }

	@property TLSCertificateInformation peerCertificate() { assert(false, "Incompatible interface method requested"); }

	// Constructs a new TLS Client Stream and connects with the specified handlers
	this(TCPConnection underlying, BotanTLSContext ctx, 
		 void delegate(in TLSAlert alert, in ubyte[] ub) alert_cb, 
		 bool delegate(in TLSSession session) hs_cb,
		 string peer_name = null, NetworkAddress peer_address = NetworkAddress.init)
	{
		m_ctx = ctx;
		m_userData = ctx.m_userData;
		m_tcp_conn = underlying;
		m_alert_cb = alert_cb;
		m_handshake_complete = hs_cb;

		assert(m_ctx.m_kind == TLSContextKind.client, "Connecting through a server context is not supported");
		// todo: add service name?
		TLSServerInformation server_info = TLSServerInformation(peer_name, peer_address.port);
		m_tls_channel = TLSBlockingChannel(&onRead, &onWrite,  &onAlert, &onHandhsakeComplete, m_ctx.m_session_manager, m_ctx.m_credentials, m_ctx.m_policy, m_ctx.m_rng, server_info, m_ctx.m_offer_version, m_ctx.m_clientOffers.dup);

		scope(exit) 
			processException();
		
		m_tls_channel.doHandshake();
	}

	// This constructor is used by the TLS Context for both server and client streams
	this(TCPConnection underlying, BotanTLSContext ctx, TLSStreamState state, string peer_name = null, NetworkAddress peer_address = NetworkAddress.init) {
		m_ctx = ctx;
		m_userData = ctx.m_userData;
		m_tcp_conn = underlying;

		if (state == TLSStreamState.accepting)
		{
			assert(m_ctx.m_kind != TLSContextKind.client, "Accepting through a client context is not supported");
			m_tls_channel = TLSBlockingChannel(&onRead, &onWrite, &onAlert, &onHandhsakeComplete, m_ctx.m_session_manager, m_ctx.m_credentials, m_ctx.m_policy, m_ctx.m_rng, &m_ctx.nextProtocolHandler, &m_ctx.sniHandler, m_ctx.m_is_datagram);
		
		}
		else if (state == TLSStreamState.connecting) {
			assert(m_ctx.m_kind == TLSContextKind.client, "Connecting through a server context is not supported");
			// todo: add service name?
			TLSServerInformation server_info = TLSServerInformation(peer_name, peer_address.port);
			m_tls_channel = TLSBlockingChannel(&onRead, &onWrite,  &onAlert, &onHandhsakeComplete, m_ctx.m_session_manager, m_ctx.m_credentials, m_ctx.m_policy, m_ctx.m_rng, server_info, m_ctx.m_offer_version, m_ctx.m_clientOffers.dup);
		}
		else /*if (state == TLSStreamState.connected)*/ {
			m_tls_channel = TLSBlockingChannel.init;
			throw new Exception("Cannot load BotanTLSSteam from a connected TLS session");
		}
		scope(exit) 
			processException();

		m_tls_channel.doHandshake();

	}

	@property bool connected() const { return m_tcp_conn.connected && !m_ex; }
	
	void close()
	{
		if (m_tcp_conn.connected) finalize();
		m_tcp_conn.close();
	}

	void flush() { 
		processException();
		m_tcp_conn.flush();
	}

	void finalize() { 
		if (m_tls_channel.isClosed())
			return;

		processException();
		scope(exit) 
			processException();

		m_tls_channel.close();
		m_tcp_conn.flush();
	}

	void write(InputStream stream, ulong nbytes) { processException(); writeDefault(stream, nbytes); }

	bool waitForData(Duration timeout = 0.seconds)
	{
		if (m_tls_channel.pending() == 0) {
			if (!m_tcp_conn.dataAvailableForRead()) {
				if (!m_tcp_conn.waitForData(timeout))
					return false;
			}

			if (!connected) return false;
			m_tls_channel.readBuf(null); // force an exchange			
		}
		return true;
	}

	void* getUserData() const
	{ 
		processException();
		assert(m_ctx.m_kind != TLSContextKind.client, "Only SNI servers may hold user data");
		if (!m_userData && !m_tls_channel.isClosed)
			(cast()this).m_userData = (cast(TLSServer)m_tls_channel.underlyingChannel()).getUserData();	
		return cast(void*) m_userData; 
	}

	void read(ubyte[] dst) { 
		processException();
		scope(exit) 
			processException();
		m_tls_channel.read(dst);
	}

	ubyte[] readBuf(ubyte[] buf) { 
		processException();
		scope(exit) 
			processException();
		return m_tls_channel.readBuf(buf);
	}

	void write(in ubyte[] src) {
		processException();
		scope(exit) 
			processException();
		m_tls_channel.write(src);
	}

	@property bool empty()
	{
		processException();
		return leastSize() == 0 && m_tcp_conn.empty;
	}
	
	@property ulong leastSize()
	{
		size_t ret = m_tls_channel.pending();
		if (ret > 0) return ret;
		waitForData();
		ret = m_tls_channel.pending();
		//logDebug("Least size returned: ", ret);
		return ret > 0 ? ret : m_tcp_conn.empty ? 0 : 1;
	}
	
	@property bool dataAvailableForRead()
	{
		processException();
		return m_tls_channel.pending() > 0 || m_tcp_conn.dataAvailableForRead;
	}
	
	const(ubyte)[] peek()
	{
		processException();
		auto peeked = m_tls_channel.peek();
		//logDebug("Peeked data: ", cast(ubyte[])peeked);
		//logDebug("Peeked data ptr: ", peeked.ptr);
		return peeked;
	}
	
	@property void setAlertCallback(void delegate(in TLSAlert alert, in ubyte[] ub) alert_cb) 
	{
		processException();
		m_alert_cb = alert_cb;
	}
	
	@property void setHandshakeCallback(bool delegate(in TLSSession session) hs_cb) 
	{
		processException();
		m_handshake_complete = hs_cb;
	}

	void processException() const {
		if (m_ex)
			throw m_ex;
	}

private:
	void onAlert(in TLSAlert alert, in ubyte[] data) {
		if (alert.isFatal)
			m_ex = new Exception("TLS Alert Received: " ~ alert.typeString());
		if (m_alert_cb)
			m_alert_cb(alert, data);
	}

	bool onHandhsakeComplete(in TLSSession session) {
		m_sess_id = cast(ubyte[])session.sessionId()[].dup;
		m_cipher = session.ciphersuite();
		m_session_age = session.startTime();
		m_ver = session.Version();
		if (session.peerCerts().length > 0)
			m_peer_cert = session.peerCerts()[0];
		if (m_handshake_complete)
			return m_handshake_complete(session);
		return true;
	}

	ubyte[] onRead(ubyte[] buf) 
	{
		ubyte[] ret;
		if (auto buffered = cast(Buffered)m_tcp_conn) {
			ret = buffered.readBuf(buf);
			return ret;
		}
		
		size_t len = std.algorithm.min(m_tcp_conn.leastSize(), buf.length);
		if (len == 0) return null;
		m_tcp_conn.read(buf[0 .. len]);
		return buf[0 .. len];
	}

	void onWrite(in ubyte[] src) {	
		//logDebug("Write: %s", src);
		m_tcp_conn.write(src);
	}

}

class BotanTLSContext : TLSContext {
private:
	TLSSessionManager m_session_manager;
	TLSPolicy m_policy;
	TLSCredentialsManager m_credentials;
	TLSContextKind m_kind;
	AutoSeededRNG m_rng;
	TLSProtocolVersion m_offer_version;
	TLSServerNameCallback m_sniCallback;
	TLSALPNCallback m_serverCb;
	Vector!string m_clientOffers;
	void* m_userData;
	bool m_is_datagram;

public:

	this(TLSContextKind kind, 
		 TLSCredentialsManager credentials = null, 
		 TLSPolicy policy = null, 
		 TLSSessionManager session_manager = null,
		 bool is_datagram = false)
	{
		if (!credentials)
			credentials = new CustomTLSCredentials();
		m_kind = kind;
		m_credentials = credentials;
		m_is_datagram = is_datagram;

		if (is_datagram)
			m_offer_version = TLSProtocolVersion.DTLS_V12;
		else
			m_offer_version = TLSProtocolVersion.TLS_V12;

		m_rng = AutoSeededRNG();
		if (!session_manager)
			session_manager = new TLSSessionManagerInMemory(m_rng);
		m_session_manager = session_manager;

		if (!policy) {
			if (!gs_default_policy)
				gs_default_policy = new CustomTLSPolicy();
			policy = cast(TLSPolicy)gs_default_policy;
		}
		m_policy = policy;
	}

	/// The kind of TLS context (client/server)
	@property TLSContextKind kind() const { 
		return m_kind;
	}

	/// Used by clients to indicate protocol preference, use TLSPolicy to restrict the protocol versions
	@property void defaultProtocolOffer(TLSProtocolVersion ver) { m_offer_version = ver; }
	/// ditto
	@property TLSProtocolVersion defaultProtocolOffer() { return m_offer_version; }

	void setUserData(void* udata) { m_userData = udata; }

	@property void sniCallback(TLSServerNameCallback callback)
	{
		m_sniCallback = callback;
	}
	@property inout(TLSServerNameCallback) sniCallback() inout { return m_sniCallback; }

	/// Callback function invoked by server to choose alpn
	@property void alpnCallback(TLSALPNCallback alpn_chooser)
	{
		m_serverCb = alpn_chooser;
	}

	/// Get the current ALPN callback function
	@property TLSALPNCallback alpnCallback() const { return m_serverCb; }

	/// Invoked by client to offer alpn, all strings are copied on the GC
	@property void setClientALPN(string[] alpn_list)
	{
		m_clientOffers.clear();
		foreach (alpn; alpn_list)
			m_clientOffers ~= alpn.idup;
	}

	/** Creates a new stream associated to this context.
	*/
	TLSStream createStream(Stream underlying, TLSStreamState state, string peer_name = null, NetworkAddress peer_address = NetworkAddress.init)
	{
		assert(cast(TCPConnection)underlying !is null, "BotanTLSStream can only be created from TCP Connections at the moment");
		return new BotanTLSStream(cast(TCPConnection)underlying, this, state, peer_name, peer_address);
	}

	/** Specifies the validation level of remote peers.

		The default mode for TLSContextKind.client is
		TLSPeerValidationMode.trustedCert and the default for
		TLSContextKind.server is TLSPeerValidationMode.none.
	*/
	@property void peerValidationMode(TLSPeerValidationMode mode) {
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			credentials.m_validationMode = mode;
			return;
		}
		else assert(false, "Cannot handle peerValidationMode if CustomTLSCredentials is not used");
	}
	/// ditto
	@property TLSPeerValidationMode peerValidationMode() const {
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			return credentials.m_validationMode;
		}
		else assert(false, "Cannot handle peerValidationMode if CustomTLSCredentials is not used");
	}

	/** An optional user callback for peer validation.

		Peer validation callback is unused in Botan. Specify a custom TLS Policy to handle peer certificate data.
	*/
	@property void peerValidationCallback(TLSPeerValidationCallback callback) { assert(false, "Peer validation callback is unused in Botan. Specify a custom TLS Policy to handle peer certificate data."); }
	/// ditto
	@property inout(TLSPeerValidationCallback) peerValidationCallback() inout { return TLSPeerValidationCallback.init; }

	/** The maximum length of an accepted certificate chain.

		Any certificate chain longer than this will result in the TLS
		negitiation failing.

		The default value is 9.
	*/
	@property void maxCertChainLength(int val) { 
		
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			credentials.m_max_cert_chain_length = val;
			return;
		}
		else assert(false, "Cannot handle maxCertChainLength if CustomTLSCredentials is not used");
	}
	/// ditto
	@property int maxCertChainLength() const {
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			return credentials.m_max_cert_chain_length;
		}
		else assert(false, "Cannot handle maxCertChainLength if CustomTLSCredentials is not used");
	}

	void setCipherList(string list = null) { assert(false, "Incompatible interface method requested"); }
	
	/** Set params to use for DH cipher.
	 *
	 * By default the 2048-bit prime from RFC 3526 is used.
	 *
	 * Params:
	 * pem_file = Path to a PEM file containing the DH parameters. Calling
	 *    this function without argument will restore the default.
	 */
	void setDHParams(string pem_file=null) { assert(false, "Incompatible interface method requested"); }
	
	/** Set the elliptic curve to use for ECDH cipher.
	 *
	 * By default a curve is either chosen automatically or  prime256v1 is used.
	 *
	 * Params:
	 * curve = The short name of the elliptic curve to use. Calling this
	 *    function without argument will restore the default.
	 *
	 */
	void setECDHCurve(string curve=null) { assert(false, "Incompatible interface method requested"); }
	
	/// Sets a certificate file to use for authenticating to the remote peer
	void useCertificateChainFile(string path) { 
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			credentials.m_server_cert = X509Certificate(path);
			return;
		}
		else assert(false, "Cannot handle useCertificateChainFile if CustomTLSCredentials is not used");
	}
	
	/// Sets the private key to use for authenticating to the remote peer based
	/// on the configured certificate chain file.
	/// todo: Use passphrase?
	void usePrivateKeyFile(string path) { 
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			import botan.pubkey.pkcs8 : loadKey;
			credentials.m_key = loadKey(path, m_rng);
			return;
		}
		else assert(false, "Cannot handle usePrivateKeyFile if CustomTLSCredentials is not used");
	}
	
	/** Sets the list of trusted certificates for verifying peer certificates.

		If this is a server context, this also entails that the given
		certificates are advertised to connecting clients during handshake.

		On Linux, the system's root certificate authority list is usually
		found at "/etc/ssl/certs/ca-certificates.crt",
		"/etc/pki/tls/certs/ca-bundle.crt", or "/etc/ssl/ca-bundle.pem".
	*/
	void useTrustedCertificateFile(string path) { 
		if (auto credentials = cast(CustomTLSCredentials)m_credentials) {
			auto store = new CertificateStoreInMemory;
			
			store.addCertificate(X509Certificate(path));
			credentials.m_stores.pushBack(store);
			return;
		} 
		else assert(false, "Cannot handle useTrustedCertificateFile if CustomTLSCredentials is not used");
	}

private:
	SNIContextSwitchInfo sniHandler(string hostname) 
	{
		auto ctx = onSNI(hostname);
		if (!ctx) return SNIContextSwitchInfo.init;
		SNIContextSwitchInfo chgctx;
		chgctx.session_manager = ctx.m_session_manager;
		chgctx.credentials = ctx.m_credentials;
		chgctx.policy = ctx.m_policy;
		chgctx.next_proto = &ctx.nextProtocolHandler;
		chgctx.user_data = ctx.m_userData; // will be used to recover the HTTP server high-level context
		return chgctx;
	}

	string nextProtocolHandler(in Vector!string offers) {
		enforce(m_kind == TLSContextKind.server, "Attempted ALPN selection on a " ~ m_kind.to!string);
		if (m_serverCb !is null)
			return m_serverCb(offers[]);
		else return "";
	}

	BotanTLSContext onSNI(string hostname) {
		if (m_kind != TLSContextKind.serverSNI)
			return null;

		TLSContext ctx = m_sniCallback(hostname);
		if (auto bctx = cast(BotanTLSContext) ctx) {
			// Since this happens in a BotanTLSStream, the stream info (r/w callback) remains the same
			return bctx;
		}

		// We cannot use anything else than a Botan stream, and any null value with serverSNI is a failure
		throw new Exception("Could not find specified hostname");
	}
}

/**
* TLS Policy as a settings object
*/
class CustomTLSPolicy : TLSPolicy
{
	TLSProtocolVersion m_min_ver = TLSProtocolVersion.SSL_V3;
	int m_min_dh_group_size = 1024;
	Vector!TLSCiphersuite m_pri_ciphersuites;
	Vector!string m_pri_ecc_curves;
	Duration m_session_lifetime = 24.hours;
	bool m_pri_ciphers_exclusive;
	bool m_pri_curves_exclusive;
	
public:
	/// Sets the minimum acceptable protocol version
	@property void minProtocolVersion(TLSProtocolVersion ver) { m_min_ver = ver; }
	
	/// Get the minimum acceptable protocol version
	@property TLSProtocolVersion minProtocolVersion() { return m_min_ver; }

	@property void minDHGroupSize(int sz) { m_min_dh_group_size = sz; }
	@property int minDHGroupSize() { return m_min_dh_group_size; }

	/// Add a cipher suite to the priority ciphers with lowest ordering value
	void addPriorityCiphersuites(TLSCiphersuite[] suites) { m_pri_ciphersuites ~= suites; }
	
	@property TLSCiphersuite[] ciphers() { return m_pri_ciphersuites[]; }
	
	/// Set to true to use excuslively priority ciphers passed through "addCiphersuites"
	@property void priorityCiphersOnly(bool b) { m_pri_ciphers_exclusive = b; }
	@property bool priorityCiphersOnly() { return m_pri_ciphers_exclusive; }
	
	void addPriorityCurves(string[] curves) {
		m_pri_ecc_curves ~= curves;
	}
	@property string[] priorityCurves() { return m_pri_ecc_curves[]; }
	
	/// Uses only priority curves passed through "add"
	@property void priorityCurvesOnly(bool b) { m_pri_curves_exclusive = b; }
	@property bool priorityCurvesOnly() { return m_pri_curves_exclusive; }

	override string chooseCurve(in Vector!string curve_names) const
	{
		import std.algorithm : countUntil;
		foreach (curve; m_pri_ecc_curves[]) {
			if (curve_names[].countUntil(curve) != -1)
				return curve;
		}

		if (!m_pri_curves_exclusive)
			return super.chooseCurve((cast(Vector!string)curve_names).move);
		return "";
	}

	override Vector!string allowedEccCurves() const {
		Vector!string ret;
		if (!m_pri_ecc_curves.empty)
			ret ~= m_pri_ecc_curves[];
		if (!m_pri_curves_exclusive)  {
			auto others = super.allowedEccCurves();
			ret ~= others[];
		}
		return ret;
	}

	override Vector!ushort ciphersuiteList(TLSProtocolVersion _version, bool have_srp) const {
		Vector!ushort ret;
		if (m_pri_ciphersuites.length > 0) {
			foreach (suite; m_pri_ciphersuites) {
				ret ~= suite.ciphersuiteCode();
			}
		}

		if (!m_pri_ciphers_exclusive) {
			ret ~= super.ciphersuiteList(_version, have_srp);
		}

		return ret;
	}

	override bool acceptableProtocolVersion(TLSProtocolVersion _version) const
	{
		if (m_min_ver != TLSProtocolVersion.init)
			return _version >= m_min_ver;
		return super.acceptableProtocolVersion(_version);
	}

	override Duration sessionTicketLifetime() const {
		return m_session_lifetime;
	}

	override size_t minimumDhGroupSize() const {
		return m_min_dh_group_size;
	}

}


class CustomTLSCredentials : TLSCredentialsManager
{

public:
	this() { }

	// Client constructor
	this(TLSPeerValidationMode validation_mode = TLSPeerValidationMode.checkPeer) {
		m_validationMode = validation_mode;
	}

	// Server constructor
	this(X509Certificate server_cert, X509Certificate ca_cert, PrivateKey server_key) 
	{
		m_server_cert = server_cert;
		m_ca_cert = ca_cert;
		m_key = server_key;
		auto store = new CertificateStoreInMemory;

		store.addCertificate(m_ca_cert);
		m_stores.pushBack(store);
		m_validationMode = TLSPeerValidationMode.none;
	}

	override Vector!CertificateStore trustedCertificateAuthorities(in string, in string)
	{
		// todo: Check machine stores for client mode

		return m_stores.dup;
	}
	
	override Vector!X509Certificate certChain(const ref Vector!string cert_key_types, in string type, in string) 
	{
		Vector!X509Certificate chain;
		
		if (type == "tls-server")
		{
			bool have_match = false;
			foreach (cert_key_type; cert_key_types[]) {
				if (cert_key_type == m_key.algoName) {
					enforce(m_server_cert, "Private Key was defined but no corresponding server certificate was found.");
					have_match = true;
				}
			}
			
			if (have_match)
			{
				chain.pushBack(m_server_cert);
				if (m_ca_cert) chain.pushBack(m_ca_cert);
			}
		}
		
		return chain.move();
	}
	
	override void verifyCertificateChain(in string type, in string purported_hostname, const ref Vector!X509Certificate cert_chain)
	{
		if (cert_chain.empty)
			throw new InvalidArgument("Certificate chain was empty");

		if (m_validationMode == TLSPeerValidationMode.validCert)
		{      			
			auto trusted_CAs = trustedCertificateAuthorities(type, purported_hostname);
			
			PathValidationRestrictions restrictions;
			restrictions.maxCertChainLength = m_max_cert_chain_length;

			auto result = x509PathValidate(cert_chain, restrictions, trusted_CAs);
			
			if (!result.successfulValidation())
				throw new Exception("Certificate validation failure: " ~ result.resultString());
			
			if (!certInSomeStore(trusted_CAs, result.trustRoot()))
				throw new Exception("Certificate chain roots in unknown/untrusted CA");
			
			if (purported_hostname != "" && !cert_chain[0].matchesDnsName(purported_hostname))
				throw new Exception("Certificate did not match hostname");

			return;
		}

		if (m_validationMode & TLSPeerValidationMode.checkTrust) {
			auto trusted_CAs = trustedCertificateAuthorities(type, purported_hostname);
			
			PathValidationRestrictions restrictions;
			restrictions.maxCertChainLength = m_max_cert_chain_length;
			
			PathValidationResult result;
			try result = x509PathValidate(cert_chain, restrictions, trusted_CAs);
			catch (Exception e) { }

			if (!certInSomeStore(trusted_CAs, result.trustRoot()))
				throw new Exception("Certificate chain roots in unknown/untrusted CA");
		}

		// Commit to basic tests for other validation modes
		if (m_validationMode & TLSPeerValidationMode.checkCert) {
			import botan.asn1.asn1_time : X509Time;
			X509Time current_time = X509Time(Clock.currTime());
			// Check all certs for valid time range
			if (current_time < X509Time(cert_chain[0].startTime()))
				throw new Exception("Certificate is not yet valid");
			
			if (current_time > X509Time(cert_chain[0].endTime()))
				throw new Exception("Certificate has expired");

			if (cert_chain[0].isSelfSigned())
				throw new Exception("Certificate was self signed");
		}

		if (m_validationMode & TLSPeerValidationMode.checkPeer)
			if (purported_hostname != "" && !cert_chain[0].matchesDnsName(purported_hostname))
				throw new Exception("Certificate did not match hostname");


	}
	
	override PrivateKey privateKeyFor(in X509Certificate, in string, in string)
	{
		return m_key;
	}
	
	// Interface fallthrough	
	override Vector!X509Certificate certChainSingleType(in string cert_key_type,
		in string type,
		in string context)
	{ return super.certChainSingleType(cert_key_type, type, context); }
	
	override bool attemptSrp(in string type, in string context)
	{ return super.attemptSrp(type, context); }
	
	override string srpIdentifier(in string type, in string context)
	{ return super.srpIdentifier(type, context); }
	
	override string srpPassword(in string type, in string context, in string identifier)
	{ return super.srpPassword(type, context, identifier); }
	
	override bool srpVerifier(in string type,
		in string context,
		in string identifier,
		ref string group_name,
		ref BigInt verifier,
		ref Vector!ubyte salt,
		bool generate_fake_on_unknown)
	{ return super.srpVerifier(type, context, identifier, group_name, verifier, salt, generate_fake_on_unknown); }
	
	override string pskIdentityHint(in string type, in string context)
	{ return super.pskIdentityHint(type, context); }
	
	override string pskIdentity(in string type, in string context, in string identity_hint)
	{ return super.pskIdentity(type, context, identity_hint); }
	
	override SymmetricKey psk(in string type, in string context, in string identity)
	{ return super.psk(type, context, identity); }
	
public:
	X509Certificate m_server_cert, m_ca_cert;
	PrivateKey m_key;
	Vector!CertificateStore m_stores;

private:
	TLSPeerValidationMode m_validationMode = TLSPeerValidationMode.none;
	int m_max_cert_chain_length = 9;
}

CustomTLSCredentials createCreds()
{
	
	import botan.rng.auto_rng;
	import botan.cert.x509.pkcs10;
	import botan.cert.x509.x509self;
	import botan.cert.x509.x509_ca;
	import botan.pubkey.algo.rsa;
	import botan.codec.hex;
	import botan.utils.types;
	auto rng = AutoSeededRNG();
	PrivateKey ca_key = RSAPrivateKey(rng, 1024);
	
	X509CertOptions ca_opts;
	ca_opts.common_name = "Test CA";
	ca_opts.country = "US";
	ca_opts.CAKey(1);
	
	X509Certificate ca_cert = x509self.createSelfSignedCert(ca_opts, ca_key, "SHA-256", rng);
	
	PrivateKey server_key = RSAPrivateKey(rng, 1024);
	
	X509CertOptions server_opts;
	server_opts.common_name = "localhost";
	server_opts.country = "US";
	
	PKCS10Request req = x509self.createCertReq(server_opts, server_key, "SHA-256", rng);
	
	X509CA ca = X509CA(ca_cert, ca_key, "SHA-256");
	
	auto now = Clock.currTime(UTC());
	X509Time start_time = X509Time(now);
	X509Time end_time = X509Time(now + 365.days);
	
	X509Certificate server_cert = ca.signRequest(req, rng, start_time, end_time);
	
	return new CustomTLSCredentials(server_cert, ca_cert, server_key);
}

private:

__gshared CustomTLSPolicy gs_default_policy;

