import EthereumKit
import WalletConnectV1
import RxSwift
import RxRelay
import CurrencyKit
import BigInt
import HsToolKit

class WalletConnectV1XMainService {
    private let disposeBag = DisposeBag()

    private let manager: WalletConnectManager
    private let sessionManager: WalletConnectSessionManager
    private let reachabilityManager: IReachabilityManager
    private let accountManager: IAccountManager

    private var interactor: WalletConnectInteractor?
    private var sessionData: SessionData?

    private var stateRelay = PublishRelay<WalletConnectXMainModule.State>()
    private var connectionStateRelay = PublishRelay<WalletConnectXMainModule.ConnectionState>()
    private var requestRelay = PublishRelay<WalletConnectRequest>()
    private var errorRelay = PublishRelay<Error>()

    private var pendingRequests = [Int: WalletConnectRequest]()
    private var requestIsProcessing = false

    private let queue = DispatchQueue(label: "io.horizontalsystems.unstoppable.wallet-connect-service", qos: .userInitiated)

    private(set) var state: WalletConnectXMainModule.State = .idle {
        didSet {
            stateRelay.accept(state)
        }
    }

    var connectionState: WalletConnectXMainModule.ConnectionState {
        guard let interactor = interactor else {
            return .disconnected
        }
        return connectionState(state: interactor.state)
    }

    init(session: WalletConnectSession? = nil, uri: String? = nil, manager: WalletConnectManager, sessionManager: WalletConnectSessionManager, reachabilityManager: IReachabilityManager, accountManager: IAccountManager) {
        self.manager = manager
        self.sessionManager = sessionManager
        self.reachabilityManager = reachabilityManager
        self.accountManager = accountManager

        if let session = session {
            restore(session: session)
        }
        if let uri = uri {
            do {
                try connect(uri: uri)

                state = .ready
            } catch {
                state = .invalid(error: error)
            }
        }

        reachabilityManager.reachabilityObservable
                .subscribeOn(ConcurrentDispatchQueueScheduler(qos: .background))
                .subscribe(onNext: { [weak self] reachable in
                    if reachable {
                        self?.interactor?.connect()
                    }
                })
                .disposed(by: disposeBag)
    }

    private func restore(session: WalletConnectSession) {
        do {
            try initSession(peerId: session.peerId, peerMeta: session.peerMeta, chainId: session.chainId)

            interactor = WalletConnectInteractor(session: session.session, remotePeerId: session.peerId)
            interactor?.delegate = self
            interactor?.connect()

            state = .ready
        } catch {
            state = .invalid(error: error)
        }
    }

    private func initSession(peerId: String, peerMeta: WCPeerMeta, chainId: Int) throws {
        guard let account = manager.activeAccount else {
            throw WalletConnectXMainModule.SessionError.noSuitableAccount
        }

        guard let evmKitWrapper = manager.evmKitWrapper(chainId: chainId, account: account) else {
            throw WalletConnectXMainModule.SessionError.unsupportedChainId
        }

        sessionData = SessionData(peerId: peerId, chainId: chainId, peerMeta: peerMeta, account: account, evmKitWrapper: evmKitWrapper)
    }

    private func handleRequest(id: Int, requestResolver: () throws -> WalletConnectRequest) {
        do {
            let request = try requestResolver()
            pendingRequests[id] = request
            processNextRequest()
        } catch {
            interactor?.rejectRequest(id: id, message: error.smartDescription)
        }
    }

    private func processNextRequest() {
        guard !requestIsProcessing else {
            return
        }

        guard let nextRequest = pendingRequests.values.first else {
            return
        }

        requestRelay.accept(nextRequest)
        requestIsProcessing = true
    }

    private func connectionState(state: WalletConnectInteractor.State) -> WalletConnectXMainModule.ConnectionState {
        switch state {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnected: return .disconnected
        }
    }

}

extension WalletConnectV1XMainService: IWalletConnectXMainService {

    var stateObservable: Observable<WalletConnectXMainModule.State> {
        stateRelay.asObservable()
    }

    var allowedBlockchains: [Int: WalletConnectXMainModule.Blockchain] {
        [:]
    }
    var allowedBlockchainsObservable: Observable<[Int: WalletConnectXMainModule.Blockchain]> {
        Observable.just([:])
    }

    var connectionStateObservable: Observable<WalletConnectXMainModule.ConnectionState> {
        connectionStateRelay.asObservable()
    }

    var requestObservable: Observable<WalletConnectRequest> {
        requestRelay.asObservable()
    }

    var errorObservable: Observable<Error> {
        errorRelay.asObservable()
    }

    var activeAccountName: String? {
        accountManager.activeAccount?.name
    }

    var appMetaItem: WalletConnectXMainModule.AppMetaItem? {
        (sessionData?.peerMeta).map {
            WalletConnectXMainModule.AppMetaItem(
                name: $0.name,
                url: $0.url,
                description: $0.description,
                icons: $0.icons
            )
        }
    }

    var hint: String? {
        switch connectionState {
        case .disconnected:
            if state == .waitingForApproveSession || state == .ready {
                return "wallet_connect.no_connection"
            }
        case .connecting: return nil
        case .connected: ()
        }

        switch state {
        case .invalid(let error):
            return error.smartDescription
        case .waitingForApproveSession:
            return "wallet_connect.connect_description"
        case .ready:
            return "wallet_connect.usage_description"
        default:
            return nil
        }
    }


    var evmKitWrapper: EvmKitWrapper? {
        sessionData?.evmKitWrapper
    }

    func toggle(chainId: Int) {

    }

    func pendingRequest(requestId: Int) -> WalletConnectRequest? {
        pendingRequests[requestId]
    }

    func connect(uri: String) throws {
        interactor = try WalletConnectInteractor(uri: uri)
        interactor?.delegate = self
        interactor?.connect()
    }

    func reconnect() {
        guard reachabilityManager.isReachable else {
            errorRelay.accept(AppError.noConnection)
            return
        }

        interactor?.delegate = self
        interactor?.connect()
    }

    func approveSession() {
        guard reachabilityManager.isReachable else {
            errorRelay.accept(AppError.noConnection)
            return
        }

        guard let interactor = interactor, let sessionData = sessionData else {
            return
        }

        interactor.approveSession(address: sessionData.evmKitWrapper.evmKit.address.eip55, chainId: sessionData.evmKitWrapper.evmKit.networkType.chainId)

        let session = WalletConnectSession(
                chainId: sessionData.evmKitWrapper.evmKit.networkType.chainId,
                accountId: sessionData.account.id,
                session: interactor.session,
                peerId: sessionData.peerId,
                peerMeta: sessionData.peerMeta
        )

        sessionManager.save(session: session)

        state = .ready
    }

    func rejectSession() {
        guard reachabilityManager.isReachable else {
            errorRelay.accept(AppError.noConnection)
            return
        }

        guard let interactor = interactor else {
            return
        }

        interactor.rejectSession(message: "Session Rejected by User")

        state = .killed
    }

    func approveRequest(id: Int, anyResult: Any) {
        guard reachabilityManager.isReachable else {
            errorRelay.accept(AppError.noConnection)
            return
        }

        queue.async {
            if let request = self.pendingRequests.removeValue(forKey: id), let convertedResult = request.convert(result: anyResult) {
                self.interactor?.approveRequest(id: id, result: convertedResult)
            }

            self.requestIsProcessing = false
            self.processNextRequest()
        }
    }

    func rejectRequest(id: Int) {
        guard reachabilityManager.isReachable else {
            errorRelay.accept(AppError.noConnection)
            return
        }

        queue.async {
            self.pendingRequests.removeValue(forKey: id)

            self.interactor?.rejectRequest(id: id, message: "Rejected by user")

            self.requestIsProcessing = false
            self.processNextRequest()
        }
    }

    func killSession() {
        guard let interactor = interactor else {
            return
        }

        interactor.killSession()
    }

}

extension WalletConnectV1XMainService: IWalletConnectInteractorDelegate {

    func didUpdate(state: WalletConnectInteractor.State) {
        connectionStateRelay.accept(connectionState(state: state))
    }

    func didRequestSession(peerId: String, peerMeta: WCPeerMeta, chainId: Int?) {
        do {
//            guard let chainId = chainId else {
//                throw SessionError.unsupportedChainId
//            }

            let chainId = chainId ?? 1 // fallback to chainId = 1 (Ethereum MainNet)

            try initSession(peerId: peerId, peerMeta: peerMeta, chainId: chainId)

            state = .waitingForApproveSession
        } catch {
            interactor?.rejectSession(message: "Session Rejected: \(error)")
            state = .invalid(error: error)
        }
    }

    func didKillSession() {
        if let sessionData = sessionData {
            sessionManager.deleteSession(peerId: sessionData.peerId)
        }

        state = .killed
    }

    func didRequestSendEthereumTransaction(id: Int, transaction: WCEthereumTransaction) {
        let chainId = sessionData?.chainId
        queue.async {
            self.handleRequest(id: id) {
                try WalletConnectSendEthereumTransactionRequest(id: id, chainId: chainId, transaction: transaction)
            }
        }
    }

    func didRequestSignEthereumTransaction(id: Int, transaction: WCEthereumTransaction) {
        print("didRequestSignEthereumTransaction")
    }

    func didRequestSign(id: Int, payload: WCEthereumSignPayload) {
        let chainId = sessionData?.chainId
        queue.async {
            self.handleRequest(id: id) {
                WalletConnectSignMessageRequest(id: id, chainId: chainId, payload: payload)
            }
        }
    }

}

extension WalletConnectV1XMainService {

    struct SessionData {
        let peerId: String
        let chainId: Int
        let peerMeta: WCPeerMeta
        let account: Account
        let evmKitWrapper: EvmKitWrapper
    }

}

extension WalletConnectV1XMainService: IWalletConnectSignService {

    func approveRequest(id: Int, result: Data) {
        approveRequest(id: id, anyResult: result)
    }

}