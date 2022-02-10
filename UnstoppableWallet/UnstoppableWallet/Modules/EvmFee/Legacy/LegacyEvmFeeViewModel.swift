import RxSwift
import RxCocoa
import RxRelay
import EthereumKit

class LegacyEvmFeeViewModel {
    private let disposeBag = DisposeBag()

    private let gasPriceService: LegacyGasPriceService
    private let feeService: IEvmFeeService
    private let coinService: CoinService
    private let cautionsFactory: SendEvmCautionsFactory

    private let resetButtonActiveRelay = BehaviorRelay<Bool>(value: false)
    private let maxFeeRelay = BehaviorRelay<String?>(value: nil)
    private let gasLimitRelay = BehaviorRelay<String>(value: "n/a")
    private let gasPriceRelay = BehaviorRelay<String>(value: "n/a")
    private let gasPriceSliderRelay = BehaviorRelay<FeeSliderViewItem?>(value: nil)
    private let cautionsRelay = BehaviorRelay<[TitledCaution]>(value: [])

    init(gasPriceService: LegacyGasPriceService, feeService: IEvmFeeService, coinService: CoinService, cautionsFactory: SendEvmCautionsFactory) {
        self.gasPriceService = gasPriceService
        self.feeService = feeService
        self.coinService = coinService
        self.cautionsFactory = cautionsFactory

        sync(transactionStatus: feeService.status)
        sync(gasPriceStatus: gasPriceService.status)

        subscribe(disposeBag, feeService.statusObservable) { [weak self] in self?.sync(transactionStatus: $0) }
        subscribe(disposeBag, gasPriceService.statusObservable) { [weak self] in self?.sync(gasPriceStatus: $0) }
    }

    private func sync(gasPriceStatus: DataStatus<FallibleData<GasPrice>>) {
        if case .completed(let fallibleGasPrice) = gasPriceStatus, case .legacy(let gasPrice) = fallibleGasPrice.data {
            let gweiGasPrice = gwei(wei: gasPrice)
            gasPriceRelay.accept("\(gweiGasPrice) gwei")
            gasPriceSliderRelay.accept(FeeSliderViewItem(initialValue: gweiGasPrice, range: gwei(range: gasPriceService.gasPriceRange)))
        } else {
            gasPriceRelay.accept("n/a".localized)
            gasPriceSliderRelay.accept(nil)
        }
    }

    private func sync(transactionStatus: DataStatus<FallibleData<EvmFeeModule.Transaction>>) {
        let maxFeeStatus: String
        let gasLimit: String
        let cautions: [TitledCaution]

        switch transactionStatus {
        case .loading:
            maxFeeStatus = "action.loading".localized
            gasLimit = "n/a".localized
            cautions = []
        case .failed(let error):
            maxFeeStatus = "n/a".localized
            gasLimit = "n/a".localized
            cautions = cautionsFactory.items(errors: [error], warnings: [], baseCoinService: coinService)
        case .completed(let fallibleTransaction):
            let gasData = fallibleTransaction.data.gasData

            maxFeeStatus = coinService.amountData(value: gasData.fee).formattedString
            gasLimit = gasData.gasLimit.description
            cautions = cautionsFactory.items(errors: fallibleTransaction.errors, warnings: fallibleTransaction.warnings, baseCoinService: coinService)
        }

        maxFeeRelay.accept(maxFeeStatus)
        gasLimitRelay.accept(gasLimit)
        cautionsRelay.accept(cautions)
    }

    private func gwei(wei: Int) -> Int {
        wei / 1_000_000_000
    }

    private func gwei(range: ClosedRange<Int>) -> ClosedRange<Int> {
        gwei(wei: range.lowerBound)...gwei(wei: range.upperBound)
    }

    private func wei(gwei: Int) -> Int {
        gwei * 1_000_000_000
    }

}

extension LegacyEvmFeeViewModel {

    var gasLimitDriver: Driver<String> {
        gasLimitRelay.asDriver()
    }

    var gasPriceDriver: Driver<String> {
        gasPriceRelay.asDriver()
    }

    var gasPriceSliderDriver: Driver<FeeSliderViewItem?> {
        gasPriceSliderRelay.asDriver()
    }

    var cautionsDriver: Driver<[TitledCaution]> {
        cautionsRelay.asDriver()
    }

    var resetButtonActiveDriver: Driver<Bool> {
        resetButtonActiveRelay.asDriver()
    }

    func set(value: Int) {
        gasPriceService.set(gasPrice: wei(gwei: value))
    }

    func reset() {
        gasPriceService.setRecommendedGasPrice()
    }

}

extension LegacyEvmFeeViewModel: IFeeViewModel {

    var maxFeeDriver: Driver<String?> {
        maxFeeRelay.asDriver()
    }

    var editButtonVisibleDriver: Driver<Bool> {
        Single<Bool>.just(false).asDriver(onErrorJustReturn: false)
    }

}
