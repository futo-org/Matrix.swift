//
//  UIAuthSession.swift
//  Circles
//
//  Created by Charles Wright on 4/26/22.
//

import Foundation
import AnyCodable
import BlindSaltSpeke

@available(macOS 12.0, *)
public class UIAuthSession: UIASession, ObservableObject {
    
    public let url: URL
    public let method: String
    //public let accessToken: String? // FIXME: Make this MatrixCredentials ???
    public let creds: Matrix.Credentials?
    @Published public var state: UIASessionState
    public var realRequestDict: [String:Codable] // The JSON fields for the "real" request behind the UIA protection
    public var storage = [String: Any]() // For holding onto data between requests, like we do on the server side
    
    // Shortcut to get around a bunch of `case let` nonsense everywhere
    public var sessionState: UIAA.SessionState? {
        switch state {
        case .connected(let sessionState):
            return sessionState
        case .inProgress(let sessionState, _):
            return sessionState
        default:
            return nil
        }
    }
    
    var completion: ((UIAuthSession,Data) async throws -> Void)?
        
    public init(method: String, url: URL,
                credentials: Matrix.Credentials? = nil,
                requestDict: [String:Codable],
                completion: ((UIAuthSession,Data) async throws -> Void)? = nil
    ) {
        self.method = method
        self.url = url
        //self.accessToken = accessToken
        self.creds = credentials
        self.state = .notConnected
        self.realRequestDict = requestDict
        self.completion = completion
        
        /*
        let initTask = Task {
            try await self.initialize()
        }
        */
    }
    
    public var sessionId: String? {
        switch state {
        case .inProgress(let uiaaState, _):
            return uiaaState.session
        default:
            return nil
        }
    }
    
    public var isFinished: Bool {
        switch self.state {
        case .finished(_):
            return true
        default:
            return false
        }
    }
    
    public func _checkBasicSanity(userInput: String) -> Bool {
        if userInput.contains(" ")
            || userInput.contains("\"")
            || userInput.isEmpty
        {
            return false
        }
        return true
    }
    
    public func _looksLikeValidEmail(userInput: String) -> Bool {
        if !_checkBasicSanity(userInput: userInput) {
            return false
        }
        if !userInput.contains("@")
            || userInput.hasPrefix("@") // Must have a user part before the @
            || userInput.hasSuffix("@") // Must have a domain part after the @
            || !userInput.contains(".") // Must have a dot somewhere
        {
            return false
        }
        
        // OK now we can bring out the big guns
        // See https://multithreaded.stitchfix.com/blog/2016/11/02/email-validation-swift/
        // And Apple's documentation on the DataDetector
        // https://developer.apple.com/documentation/foundation/nsdatadetector
        guard let dataDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else {
            return false
        }
        
        let range = NSMakeRange(0, NSString(string: userInput).length)
        let allMatches = dataDetector.matches(in: userInput,
                                              options: [],
                                              range: range)
        if allMatches.count == 1,
            allMatches.first?.url?.absoluteString.contains("mailto:") == true
        {
            return true
        }
        return false
    }
    
    // MARK: connect()
    
    public func connect() async throws {
        let tag = "UIA(init)"
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken = self.creds?.accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        if url.path.contains("/register") {
            let emptyDict = [String:AnyCodable]()
            request.httpBody = try encoder.encode(emptyDict)
        }
        else {
            let anyCodableRequestDict: [String:AnyCodable] = realRequestDict.mapValues {
                AnyCodable($0)
            }
            request.httpBody = try encoder.encode(anyCodableRequestDict)
            let requestBody = String(decoding: request.httpBody!, as: UTF8.self)
            print("\(tag)\t\(requestBody)")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        
        print("\(tag)\tTrying to parse the response")
        guard let httpResponse = response as? HTTPURLResponse else {
            let msg = "Couldn't decode HTTP response"
            print("\(tag)\t\(msg)")
            throw Matrix.Error(msg)
        }
        print("\(tag)\tParsed HTTP response")
        
        if httpResponse.statusCode == 200 {
            await MainActor.run {
                self.state = .finished(data)
            }
            if let block = completion {
                try await block(self,data)
            }
            return
        }
        
        guard httpResponse.statusCode == 401 else {
            let msg = "Got unexpected HTTP response code (\(httpResponse.statusCode))"
            print("\(tag)\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        print("Raw HTTP response:")
        let rawStringResponse = String(data: data, encoding: .utf8)!
        print(rawStringResponse)
        
        let decoder = JSONDecoder()
        //decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        guard let sessionState = try? decoder.decode(UIAA.SessionState.self, from: data) else {
            let msg = "Couldn't decode response"
            print("\(tag)\t\(msg)")
            throw Matrix.Error(msg)
        }
        print("\(tag)\tGot a new UIA session")
        
        //self.state = .inProgress(sessionState)
        await MainActor.run {
            self.state = .connected(sessionState)
        }
    }
    
    // MARK: selectFlow()
    
    public func selectFlow(flow: UIAA.Flow) async {
        guard case .connected(let uiaState) = state else {
            // throw some error
            return
        }
        guard uiaState.flows.contains(flow) else {
            // throw some error
            return
        }
        await MainActor.run {
            self.state = .inProgress(uiaState, flow.stages)
        }
    }
    
    // MARK: Dummy stage
    
    public func doDummyAuthStage() async throws {
        let authDict = [
            "type": AUTH_TYPE_DUMMY
        ]
        
        try await doUIAuthStage(auth: authDict)
    }
    
    // MARK: Password stages
    
    public func doPasswordAuthStage(password: String) async throws {

        // Added base64 encoding here to prevent a possible injection attack on the password field
        let base64Password = Data(password.utf8).base64EncodedString()

        let passwordAuthDict: [String: String] = [
            "type": AUTH_TYPE_LOGIN_PASSWORD,
            "password": base64Password,
        ]
        
        try await doUIAuthStage(auth: passwordAuthDict)
    }
    
    public func doPasswordEnrollStage(newPassword: String) async throws {
        let base64Password = Data(newPassword.utf8).base64EncodedString()

        let passwordAuthDict: [String: String] = [
            "type": AUTH_TYPE_ENROLL_PASSWORD,
            "new_password": base64Password,
        ]
        
        try await doUIAuthStage(auth: passwordAuthDict)
    }

    // MARK: Terms stage
    
    public func doTermsStage() async throws {
        let auth: [String: String] = [
            "type": AUTH_TYPE_TERMS,
        ]
        try await doUIAuthStage(auth: auth)
    }
    
    // MARK: doUIAuthStage()
    
    // FIXME: We need some way to know if this succeeded or failed
    public func doUIAuthStage(auth: [String:Codable]) async throws {
        guard let AUTH_TYPE = auth["type"] as? String else {
            print("No auth type")
            return
        }
        let tag = "UIA(\(AUTH_TYPE))"
        
        print("\(tag)\tValidating")
        
        guard case .inProgress(let uiaState, let stages) = state else {
            let msg = "Signup session must be started before attempting stages"
            print("\(tag)\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        // Check to make sure that AUTH_TYPE is the next one in our list of stages???
        guard stages.first == AUTH_TYPE
        else {
            let msg = "Attempted stage \(AUTH_TYPE) but next required stage is [\(stages.first ?? "none")]"
            print("\(tag)\t\(msg)")
            throw Matrix.Error("Incorrect next stage: \(AUTH_TYPE)")
        }
        
        print("\(tag)\tStarting")
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // We want to be generic: Handle both kinds of use cases: (1) signup (no access token) and (2) re-auth (already have an access token, but need to re-verify identity)
        if let accessToken = self.creds?.accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        // Convert to AnyCodable because Codable is too dumb to, you know, encode things
        var requestBodyDict: [String: AnyCodable] = self.realRequestDict.mapValues {
            AnyCodable($0)
        }
        // Doh!  The caller doesn't need to care about the session id,
        // so it does not include "session" in its auth dict.
        // Therefore we have to include it before we send the request.
        var authWithSessionId = auth
        authWithSessionId["session"] = uiaState.session
        requestBodyDict["auth"] = AnyCodable(authWithSessionId)
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBodyDict)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        print("\(tag)\tGot response")
        let stringResponse = String(data: data, encoding: .utf8)!
        print(stringResponse)
        
        guard let httpResponse = response as? HTTPURLResponse
        else {
            let msg = "Couldn't decode UI auth stage response"
            print("\(tag)\tError: \(msg)")
            throw Matrix.Error(msg)
        }
        
        guard [200,401].contains(httpResponse.statusCode)
        else {
            let msg = "UI auth stage failed"
            print("\(tag)\tError: \(msg)")
            print("\(tag)\tStatus Code: \(httpResponse.statusCode)")
            print("\(tag)\tRaw response: \(stringResponse)")
            throw Matrix.Error(msg)
        }
        
        if httpResponse.statusCode == 200 {
            print("\(tag)\tAll done!")
            await MainActor.run {
                state = .finished(data)
            }
            if let block = completion {
                try await block(self,data)
            }
            return
        }
        
        let decoder = JSONDecoder()
        guard let newUiaaState = try? decoder.decode(UIAA.SessionState.self, from: data)
        else {
            let msg = "Couldn't decode UIA response"
            print("\(tag)\tError: \(msg)")
            let rawDataString = String(data: data, encoding: .utf8)!
            print("\(tag)\tRaw response:\n\(rawDataString)")
            throw Matrix.Error(msg)
        }
        
        if let completed = newUiaaState.completed {
            if completed.contains(AUTH_TYPE) {
                print("\(tag)\tComplete")
                let newStages: [String] = Array(stages.suffix(from: 1))
                await MainActor.run {
                    state = .inProgress(newUiaaState,newStages)
                }
                print("New UIA state:")
                print("\tFlows:\t\(newUiaaState.flows)")
                print("\tCompleted:\t\(completed)")
                if let params = newUiaaState.params {
                    print("\tParams:\t\(params)")
                }
                print("\tStages:\t\(newStages)")

            } else {
                print("\(tag)\tStage isn't complete???  Completed = \(completed)")
            }
        } else {
            print("\(tag)\tNo completed stages :(")
        }
        
    }
    
    
    // MARK: (New) Email stages
    
    public func doEmailRequestTokenStage(email: String) async throws -> String? {

        guard _looksLikeValidEmail(userInput: email) == true
        else {
            let msg = "Invalid email address"
            print("Email signup Error: \(msg)")
            throw Matrix.Error(msg)
        }
        
        let clientSecretNumber = UInt64.random(in: 0 ..< UInt64.max)
        let clientSecret = String(format: "%016x", clientSecretNumber)
        
        let emailAuthDict: [String: String] = [
            "type": AUTH_TYPE_ENROLL_EMAIL_REQUEST_TOKEN,
            "email": email,
            "client_secret": clientSecret,
        ]
        
        // FIXME: We need to know if this succeeded or failed
        try await doUIAuthStage(auth: emailAuthDict)
        
        return clientSecret
    }
    
    public func doEmailSubmitTokenStage(token: String, secret: String) async throws {
        let emailAuthDict: [String: String] = [
            "type": AUTH_TYPE_ENROLL_EMAIL_SUBMIT_TOKEN,
            "token": token,
            "client_secret": secret,
        ]
        try await doUIAuthStage(auth: emailAuthDict)
    }
    

    // MARK: BS-SPEKE protocol support
    
    // NOTE: The ..OPRF.. functions for Signup and Login are *almost* but not exactly duplicates of each other.
    //       The SignupSession needs a userId:password: version of the Enroll OPRF,
    //       because it isn't logged in with a userId yet.
    //       The LoginSession needs the same thing too, for the same reason.
    //       The "normal" UIAuthSession should always use the simple password: version when already logged in.
    public func doBSSpekeEnrollOprfStage(password: String) async throws {
        guard let userId = self.creds?.userId else {
            let msg = "Couldn't find user id for BS-SPEKE enrollment"
            print(msg)
            throw Matrix.Error(msg)
        }
        try await self.doBSSpekeEnrollOprfStage(userId: userId, password: password)
    }
    
    public func doBSSpekeEnrollOprfStage(userId: UserId, password: String) async throws {

        let stage = AUTH_TYPE_ENROLL_BSSPEKE_OPRF
        
        // Make sure that nobody is up to any shenanigans, calling this with a fake userId when already logged in
        if let creds = self.creds {
            guard userId == creds.userId else {
                throw Matrix.Error("BS-SPEKE: Can't enroll for a new user id while already logged in")
            }
        }
        
        guard let homeserver = self.url.host,
              homeserver.hasSuffix(userId.domain)
        else {
            throw Matrix.Error("Homeserver [\(self.url.host ?? "(none)")] does not match requested domain [\(userId.domain)]")
        }
        
        let bss = try BlindSaltSpeke.ClientSession(clientId: "\(userId)", serverId: userId.domain, password: password)
        let blind = bss.generateBlind()
        let args: [String: String] = [
            "type": stage,
            "blind": Data(blind).base64EncodedString(),
            "curve": "curve25519",
        ]
        self.storage[stage+".state"] = bss
        try await doUIAuthStage(auth: args)
    }
    
    public func b64decode(_ str: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: str) else {
            return nil
        }
        let array = [UInt8](data)
        return array
    }
    
    public func doBSSpekeEnrollSaveStage() async throws {
        // Need to send
        // V, our long-term public key (from "verifier"?  Although here the actual verifiers are hashes.)
        // P, our base point on the curve
        let stageId = UIAA.StageId(AUTH_TYPE_ENROLL_BSSPEKE_SAVE)!
        let oprfStageId = UIAA.StageId(AUTH_TYPE_ENROLL_BSSPEKE_OPRF)!
        
        guard let bss = self.storage[AUTH_TYPE_ENROLL_BSSPEKE_OPRF+".state"] as? BlindSaltSpeke.ClientSession
        else {
            let msg = "Couldn't find saved BS-SPEKE session"
            print("BS-SPEKE\tError: \(msg)")
            throw Matrix.Error(msg)
        }
        guard let oprfParams = self.sessionState?.params?[oprfStageId] as? BSSpekeOprfParams,
              let params = self.sessionState?.params?[stageId] as? BSSpekeEnrollParams
        else {
            let msg = "Couldn't find BS-SPEKE enroll params"
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        guard let blindSalt = b64decode(params.blindSalt)
        else {
            let msg = "Failed to decode base64 blind salt"
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        let blocks = [100_000, oprfParams.phfParams.blocks].max()!
        let iterations = [3, oprfParams.phfParams.iterations].max()!
        let phfParams = BSSpekeOprfParams.PHFParams(name: "argon2i",
                                                    iterations: iterations,
                                                    blocks: blocks)

        guard let (P,V) = try? bss.generatePandV(blindSalt: blindSalt, phfBlocks: UInt32(blocks), phfIterations: UInt32(iterations))
        else {
            let msg = "Failed to generate public key"
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        let args: [String: Codable] = [
            "type": stageId.stringValue,
            "P": Data(P).base64EncodedString(),
            "V": Data(V).base64EncodedString(),
            "phf_params": phfParams,
        ]
        try await doUIAuthStage(auth: args)
    }
    
    // NOTE: Just as the SignupSession needs a userId:password: version of the Enroll OPRF,
    //       here we also need a userId:password: version of the Login OPRF for the LoginSession.
    //       The "normal" UIAuthSession should always use the simple password: version when already logged in.
    public func doBSSpekeLoginOprfStage(password: String) async throws {
        guard let userId = self.creds?.userId ?? self.storage["userId"] as? UserId
        else {
            let msg = "Couldn't find user id for BS-SPEKE login"
            print(msg)
            throw Matrix.Error(msg)
        }
        try await self.doBSSpekeLoginOprfStage(userId: userId, password: password)
    }
    
    public func doBSSpekeLoginOprfStage(userId: UserId, password: String) async throws {
        let stage = AUTH_TYPE_LOGIN_BSSPEKE_OPRF
        
        // Make sure that nobody is up to any shenanigans, calling this with a fake userId when already logged in
        if let creds = self.creds {
            guard userId == creds.userId else {
                throw Matrix.Error("BS-SPEKE: Can't authenticate with a different user id while already logged in")
            }
        }
        
        let bss = try BlindSaltSpeke.ClientSession(clientId: "\(userId)", serverId: userId.domain, password: password)
        let blind = bss.generateBlind()
        let args: [String: String] = [
            "type": stage,
            "blind": Data(blind).base64EncodedString(),
            "curve": "curve25519",
        ]
        self.storage[stage+".state"] = bss
        try await doUIAuthStage(auth: args)
    }
    
    
    
    public func doBSSpekeLoginVerifyStage() async throws {
        // Need to send
        // V, our long-term public key (from "verifier"?  Although here the actual verifiers are hashes.)
        // P, our base point on the curve
        let stageId = UIAA.StageId(AUTH_TYPE_LOGIN_BSSPEKE_VERIFY)!
        let oprfStageId = UIAA.StageId(AUTH_TYPE_LOGIN_BSSPEKE_OPRF)!
        
        guard let bss = self.storage[AUTH_TYPE_LOGIN_BSSPEKE_OPRF+".state"] as? BlindSaltSpeke.ClientSession
        else {
            let msg = "Couldn't find saved BS-SPEKE session"
            print("BS-SPEKE\tError: \(msg)")
            throw Matrix.Error(msg)
        }
        
        guard let oprfParams = self.sessionState?.params?[oprfStageId] as? BSSpekeOprfParams,
              let params = self.sessionState?.params?[stageId] as? BSSpekeVerifyParams
        else {
            let msg = "Couldn't find BS-SPEKE enroll params"
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        guard let B = b64decode(params.B)
        else {
            let msg = "Failed to decode base64 server public key B"
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        guard let blindSalt = b64decode(params.blindSalt)
        else {
            let msg = "Failed to decode base64 blind salt"
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        let blocks = oprfParams.phfParams.blocks
        let iterations = oprfParams.phfParams.iterations
        guard blocks >= 100_000,
              iterations >= 3
        else {
            let msg = "PHF parameters from the server are below minimum values. Possible attack detected."
            print("BS-SPEKE\t\(msg)")
            throw Matrix.Error(msg)
        }
        
        let A = try bss.generateA(blindSalt: blindSalt, phfBlocks: UInt32(blocks), phfIterations: UInt32(iterations))
        bss.deriveSharedKey(serverPubkey: B)
        let verifier = bss.generateVerifier()
        
        let args: [String: String] = [
            "type": stageId.stringValue,
            "A": Data(A).base64EncodedString(),
            "verifier": Data(verifier).base64EncodedString(),
        ]
        print("BS-SPEKE: About to send args \(args)")
        
        try await doUIAuthStage(auth: args)
    }
    
    public func getBSSpekeClient() -> BlindSaltSpeke.ClientSession? {
        // NOTE: It's possible that we might have more than one BS-SPEKE client here
        //       If we just changed our password, then we would have one client to authenticate with the old password,
        //       and one client to enroll with the new one.
        //       When this happens, we prefer the newer "enroll" client that used the most current password,
        //       so that we can generate the most current version of our encryption key(s).
        
        if let bss = self.storage[AUTH_TYPE_ENROLL_BSSPEKE_OPRF+".state"] as? BlindSaltSpeke.ClientSession {
            return bss
        }
        
        if let bss = self.storage[AUTH_TYPE_LOGIN_BSSPEKE_OPRF+".state"] as? BlindSaltSpeke.ClientSession {
            return bss
        }
        
        return nil
    }
    
}