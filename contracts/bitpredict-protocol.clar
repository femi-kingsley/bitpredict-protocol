;; Title: BitPredict Protocol
;; Summary: Decentralized Bitcoin Price Prediction Markets on Stacks
;; Description: A trustless prediction market protocol that enables users to
;;              stake STX tokens on Bitcoin price movements. Leverages Stacks
;;              Layer 2 infrastructure for efficient settlement while maintaining
;;              Bitcoin-native security guarantees through oracle-based price feeds.
;;              Features proportional reward distribution, configurable parameters,
;;              and automated market resolution for transparent price discovery.

;; CONSTANTS & ERROR HANDLING

;; Administrative Constants
(define-constant CONTRACT-OWNER tx-sender)

;; Error Code Definitions - Comprehensive error handling for all operations
(define-constant ERR-OWNER-ONLY (err u100)) ;; Unauthorized access attempt
(define-constant ERR-NOT-FOUND (err u101)) ;; Market or prediction not found
(define-constant ERR-INVALID-PREDICTION (err u102)) ;; Invalid prediction parameters
(define-constant ERR-MARKET-CLOSED (err u103)) ;; Market outside trading window
(define-constant ERR-ALREADY-CLAIMED (err u104)) ;; Winnings already claimed
(define-constant ERR-INSUFFICIENT-BALANCE (err u105)) ;; Insufficient STX balance
(define-constant ERR-INVALID-PARAMETER (err u106)) ;; Invalid function parameter

;; STATE VARIABLES - Platform Configuration

;; Oracle Configuration - Trusted price feed source
(define-data-var oracle-address principal 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)

;; Economic Parameters - Configurable platform economics
(define-data-var minimum-stake uint u1000000) ;; 1 STX minimum stake (micro-STX)
(define-data-var fee-percentage uint u2) ;; 2% platform fee on winnings
(define-data-var market-counter uint u0) ;; Global market identifier counter

;; DATA STRUCTURES - Core Protocol Storage

;; Market Data Structure
;; Comprehensive market state including pricing, stakes, and timing parameters
(define-map markets
    uint ;; Market ID
    {
        start-price: uint, ;; Initial Bitcoin price snapshot (micro-units)
        end-price: uint, ;; Final Bitcoin price (set upon resolution)
        total-up-stake: uint, ;; Aggregate STX staked on price increase
        total-down-stake: uint, ;; Aggregate STX staked on price decrease
        start-block: uint, ;; Market opening block height
        end-block: uint, ;; Market closing block height
        resolved: bool, ;; Resolution status flag
    }
)

;; User Prediction Registry
;; Individual user positions within specific prediction markets
(define-map user-predictions
    {
        market-id: uint, ;; Market identifier
        user: principal, ;; Participant address
    }
    {
        prediction: (string-ascii 4), ;; Direction: "up" or "down"
        stake: uint, ;; STX amount staked
        claimed: bool, ;; Payout claim status
    }
)

;; CORE PUBLIC FUNCTIONS - Primary Protocol Operations

;; Create New Prediction Market
;; Establishes a new Bitcoin price prediction market with defined parameters
(define-public (create-market
        (start-price uint)
        (start-block uint)
        (end-block uint)
    )
    (let ((market-id (var-get market-counter)))
        ;; Authorization check - Only contract owner can create markets
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
        ;; Parameter validation
        (asserts! (> end-block start-block) ERR-INVALID-PARAMETER)
        (asserts! (> start-price u0) ERR-INVALID-PARAMETER)
        ;; Initialize market with default values
        (map-set markets market-id {
            start-price: start-price,
            end-price: u0,
            total-up-stake: u0,
            total-down-stake: u0,
            start-block: start-block,
            end-block: end-block,
            resolved: false,
        })
        ;; Increment global market counter
        (var-set market-counter (+ market-id u1))
        (ok market-id)
    )
)

;; Place Prediction Stake
;; Enables users to stake STX tokens on Bitcoin price direction prediction
(define-public (make-prediction
        (market-id uint)
        (prediction (string-ascii 4))
        (stake uint)
    )
    (let (
            (market (unwrap! (map-get? markets market-id) ERR-NOT-FOUND))
            (current-block stacks-block-height)
        )
        ;; Market timing validation - Ensure market is active
        (asserts!
            (and
                (>= current-block (get start-block market))
                (< current-block (get end-block market))
            )
            ERR-MARKET-CLOSED
        )
        ;; Prediction parameter validation
        (asserts! (or (is-eq prediction "up") (is-eq prediction "down"))
            ERR-INVALID-PREDICTION
        )
        (asserts! (>= stake (var-get minimum-stake)) ERR-INVALID-PREDICTION)
        (asserts! (<= stake (stx-get-balance tx-sender)) ERR-INSUFFICIENT-BALANCE)
        ;; Transfer stake from user to contract escrow
        (try! (stx-transfer? stake tx-sender (as-contract tx-sender)))
        ;; Record user prediction in registry
        (map-set user-predictions {
            market-id: market-id,
            user: tx-sender,
        } {
            prediction: prediction,
            stake: stake,
            claimed: false,
        })
        ;; Update market stake totals based on prediction direction
        (map-set markets market-id
            (merge market {
                total-up-stake: (if (is-eq prediction "up")
                    (+ (get total-up-stake market) stake)
                    (get total-up-stake market)
                ),
                total-down-stake: (if (is-eq prediction "down")
                    (+ (get total-down-stake market) stake)
                    (get total-down-stake market)
                ),
            })
        )
        (ok true)
    )
)

;; Resolve Market with Oracle Price Feed
;; Oracle-authorized function to set final Bitcoin price and resolve market
(define-public (resolve-market
        (market-id uint)
        (end-price uint)
    )
    (let ((market (unwrap! (map-get? markets market-id) ERR-NOT-FOUND)))
        ;; Oracle authorization check
        (asserts! (is-eq tx-sender (var-get oracle-address)) ERR-OWNER-ONLY)
        ;; Timing validation - Market must be closed for betting
        (asserts! (>= stacks-block-height (get end-block market))
            ERR-MARKET-CLOSED
        )
        (asserts! (not (get resolved market)) ERR-MARKET-CLOSED)
        (asserts! (> end-price u0) ERR-INVALID-PARAMETER)
        ;; Update market with final price and resolution status
        (map-set markets market-id
            (merge market {
                end-price: end-price,
                resolved: true,
            })
        )
        (ok true)
    )
)