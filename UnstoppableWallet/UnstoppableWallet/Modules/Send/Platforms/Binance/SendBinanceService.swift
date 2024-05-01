import Foundation
import HsToolKit
import MarketKit
import RxRelay
import RxSwift

class SendBinanceService {
    private let disposeBag = DisposeBag()
    private let scheduler = SerialDispatchQueueScheduler(qos: .userInitiated, internalSerialQueueName: "\(AppConfig.label).send-bitcoin-service")

    let token: Token
    let mode: PreSendViewModel.Mode

    private let amountService: IAmountInputService
    private let amountCautionService: SendAmountCautionService
    private let addressService: AddressService
    private let memoService: SendMemoInputService
    private let adapter: ISendBinanceAdapter

    private let stateRelay = PublishRelay<SendBaseService.State>()
    private(set) var state: SendBaseService.State = .notReady {
        didSet {
            stateRelay.accept(state)
        }
    }

    init(amountService: IAmountInputService, amountCautionService: SendAmountCautionService, addressService: AddressService, memoService: SendMemoInputService, adapter: ISendBinanceAdapter, reachabilityManager: IReachabilityManager, token: Token, mode: PreSendViewModel.Mode) {
        self.amountService = amountService
        self.amountCautionService = amountCautionService
        self.addressService = addressService
        self.memoService = memoService
        self.adapter = adapter
        self.token = token
        self.mode = mode

        switch mode {
        case let .prefilled(address, amount):
            addressService.set(text: address)
            if let amount { addressService.publishAmountRelay.accept(amount) }
        case let .predefined(address): addressService.set(text: address)
        case .regular: ()
        }

        subscribe(MainScheduler.instance, disposeBag, reachabilityManager.reachabilityObservable) { [weak self] isReachable in
            if isReachable {
                self?.syncState()
            }
        }

        subscribe(scheduler, disposeBag, amountService.amountObservable) { [weak self] _ in self?.syncState() }
        subscribe(scheduler, disposeBag, amountCautionService.amountCautionObservable) { [weak self] _ in self?.syncState() }
        subscribe(scheduler, disposeBag, addressService.stateObservable) { [weak self] _ in self?.syncState() }
    }

    private func syncState() {
        guard amountCautionService.amountCaution == nil,
              !amountService.amount.isZero
        else {
            state = .notReady
            return
        }

        if addressService.state.isLoading {
            state = .loading
            return
        }

        guard addressService.state.address != nil else {
            state = .notReady
            return
        }

        if adapter.fee > adapter.availableBinanceBalance {
            state = .notReady
            return
        }

        state = .ready
    }
}

extension SendBinanceService: ISendBaseService {
    var stateObservable: Observable<SendBaseService.State> {
        stateRelay.asObservable()
    }
}

extension SendBinanceService: ISendService {
    func sendSingle(logger _: Logger) -> Single<Void> {
        let address: Address
        switch addressService.state {
        case let .success(sendAddress): address = sendAddress
        case let .fetchError(error): return Single.error(error)
        default: return Single.error(AppError.addressInvalid)
        }

        guard adapter.fee <= adapter.availableBinanceBalance else {
            return Single.error(SendTransactionError.noFee)
        }

        guard !amountService.amount.isZero else {
            return Single.error(SendTransactionError.wrongAmount)
        }

        return adapter.sendSingle(
            amount: amountService.amount,
            address: address.raw,
            memo: memoService.memo
        )
    }
}

extension SendBinanceService: ISendXFeeValueService {
    var editable: Bool {
        false
    }

    var feeState: DataStatus<Decimal> {
        .completed(adapter.fee)
    }

    var feeStateObservable: Observable<DataStatus<Decimal>> {
        .just(feeState)
    }
}

extension SendBinanceService: IAvailableBalanceService {
    var availableBalance: DataStatus<Decimal> {
        .completed(adapter.availableBalance)
    }

    var availableBalanceObservable: Observable<DataStatus<Decimal>> {
        .just(availableBalance)
    }
}
