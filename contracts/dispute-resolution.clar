;; dispute-resolution
;; Smart contract for arbitrating disputes between freelancers and clients

;; Constants and Error Codes
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u900))
(define-constant ERR-NOT-FOUND (err u901))
(define-constant ERR-INVALID-PARAMS (err u902))
(define-constant ERR-DISPUTE-CLOSED (err u903))
(define-constant ERR-ALREADY-VOTED (err u904))
(define-constant ERR-NOT-ARBITRATOR (err u905))
(define-constant ERR-EVIDENCE-PERIOD-CLOSED (err u906))

;; Dispute Status Constants
(define-constant DISPUTE-CREATED u1)
(define-constant DISPUTE-EVIDENCE-PHASE u2)
(define-constant DISPUTE-VOTING-PHASE u3)
(define-constant DISPUTE-RESOLVED u4)
(define-constant DISPUTE-APPEALED u5)

;; Resolution Outcomes
(define-constant OUTCOME-FAVOR-CLIENT u1)
(define-constant OUTCOME-FAVOR-FREELANCER u2)
(define-constant OUTCOME-SPLIT-PAYMENT u3)
(define-constant OUTCOME-FULL-REFUND u4)

;; Data Variables
(define-data-var next-dispute-id uint u1)
(define-data-var total-disputes uint u0)
(define-data-var arbitrator-count uint u0)
(define-data-var min-arbitrators uint u3)

;; Data Maps
(define-map disputes
  { dispute-id: uint }
  {
    escrow-id: uint,
    plaintiff: principal,
    defendant: principal,
    status: uint,
    created-at: uint,
    evidence-deadline: uint,
    voting-deadline: uint,
    resolution: (optional uint),
    payment-split: (optional uint), ;; percentage to freelancer (0-100)
    resolved-at: (optional uint)
  }
)

(define-map arbitrators
  { arbitrator: principal }
  {
    active: bool,
    cases-resolved: uint,
    reputation: uint,
    stake-amount: uint,
    registered-at: uint
  }
)

(define-map dispute-assignments
  { dispute-id: uint, arbitrator: principal }
  { assigned: bool, voted: bool, vote: (optional uint) }
)

(define-map evidence-submissions
  { dispute-id: uint, submitter: principal, evidence-id: uint }
  {
    evidence-hash: (string-ascii 64),
    description: (string-ascii 200),
    submitted-at: uint
  }
)

(define-map dispute-votes
  { dispute-id: uint }
  {
    votes-client: uint,
    votes-freelancer: uint,
    votes-split: uint,
    total-votes: uint
  }
)

(define-map arbitrator-performance
  { arbitrator: principal }
  {
    total-cases: uint,
    correct-decisions: uint,
    accuracy-rate: uint
  }
)

;; Private Helper Functions
(define-private (inc (x uint)) (+ x u1))

(define-private (calculate-evidence-deadline)
  (+ stacks-block-height u1008) ;; 7 days
)

(define-private (calculate-voting-deadline (evidence-deadline uint))
  (+ evidence-deadline u720) ;; 5 more days
)

(define-private (is-arbitrator-eligible (arbitrator principal))
  (match (map-get? arbitrators { arbitrator: arbitrator })
    arb-data (and (get active arb-data) (>= (get reputation arb-data) u70))
    false
  )
)

(define-private (select-arbitrators (dispute-id uint))
  ;; Simplified arbitrator selection - in production would be more sophisticated
  (begin
    (map-set dispute-assignments { dispute-id: dispute-id, arbitrator: 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM }
      { assigned: true, voted: false, vote: none })
    (map-set dispute-assignments { dispute-id: dispute-id, arbitrator: 'ST2CY5V39NHDPWSXMW9QDT3HC3GD6Q6XX4CFRK9AG }
      { assigned: true, voted: false, vote: none })
    (map-set dispute-assignments { dispute-id: dispute-id, arbitrator: 'ST2JHG361ZXG51QTKY2NQCVBPPRRE2KZB1HR05NNC }
      { assigned: true, voted: false, vote: none })
    true
  )
)

(define-private (calculate-majority-decision (dispute-id uint))
  (let (
        (votes (default-to { votes-client: u0, votes-freelancer: u0, votes-split: u0, total-votes: u0 }
                          (map-get? dispute-votes { dispute-id: dispute-id })))
      )
    (if (>= (get votes-client votes) u2)
      OUTCOME-FAVOR-CLIENT
      (if (>= (get votes-freelancer votes) u2)
        OUTCOME-FAVOR-FREELANCER
        (if (>= (get votes-split votes) u2)
          OUTCOME-SPLIT-PAYMENT
          OUTCOME-SPLIT-PAYMENT ;; Default to split if no clear majority
        )
      )
    )
  )
)

;; Public Functions

;; Register as an arbitrator
(define-public (register-arbitrator (stake-amount uint))
  (begin
    (asserts! (> stake-amount u100000) ERR-INVALID-PARAMS) ;; Minimum stake
    (asserts! (is-none (map-get? arbitrators { arbitrator: tx-sender })) ERR-INVALID-PARAMS)
    
    (map-set arbitrators { arbitrator: tx-sender }
      {
        active: true,
        cases-resolved: u0,
        reputation: u100, ;; Start with perfect reputation
        stake-amount: stake-amount,
        registered-at: stacks-block-height
      }
    )
    
    (var-set arbitrator-count (inc (var-get arbitrator-count)))
    (ok true)
  )
)

;; Create a new dispute
(define-public (create-dispute
  (escrow-id uint)
  (defendant principal)
  (dispute-reason (string-ascii 200))
  )
  (let (
        (dispute-id (var-get next-dispute-id))
        (evidence-deadline (calculate-evidence-deadline))
        (voting-deadline (calculate-voting-deadline evidence-deadline))
      )
    (asserts! (> escrow-id u0) ERR-INVALID-PARAMS)
    (asserts! (not (is-eq tx-sender defendant)) ERR-INVALID-PARAMS)
    
    ;; Create dispute record
    (map-set disputes { dispute-id: dispute-id }
      {
        escrow-id: escrow-id,
        plaintiff: tx-sender,
        defendant: defendant,
        status: DISPUTE-CREATED,
        created-at: stacks-block-height,
        evidence-deadline: evidence-deadline,
        voting-deadline: voting-deadline,
        resolution: none,
        payment-split: none,
        resolved-at: none
      }
    )
    
    ;; Initialize vote tracking
    (map-set dispute-votes { dispute-id: dispute-id }
      { votes-client: u0, votes-freelancer: u0, votes-split: u0, total-votes: u0 }
    )
    
    ;; Assign arbitrators
    (select-arbitrators dispute-id)
    
    ;; Update dispute to evidence phase
    (map-set disputes { dispute-id: dispute-id }
      (merge (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-NOT-FOUND)
             { status: DISPUTE-EVIDENCE-PHASE })
    )
    
    (var-set next-dispute-id (inc dispute-id))
    (var-set total-disputes (inc (var-get total-disputes)))
    
    (ok dispute-id)
  )
)

;; Submit evidence for a dispute
(define-public (submit-evidence
  (dispute-id uint)
  (evidence-hash (string-ascii 64))
  (description (string-ascii 200))
  )
  (let (
        (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-NOT-FOUND))
        (evidence-id (+ dispute-id (* stacks-block-height u1000)))
      )
    (asserts! (is-eq (get status dispute) DISPUTE-EVIDENCE-PHASE) ERR-INVALID-PARAMS)
    (asserts! (<= stacks-block-height (get evidence-deadline dispute)) ERR-EVIDENCE-PERIOD-CLOSED)
    (asserts! (or (is-eq tx-sender (get plaintiff dispute))
                  (is-eq tx-sender (get defendant dispute))) ERR-NOT-AUTHORIZED)
    
    (map-set evidence-submissions { dispute-id: dispute-id, submitter: tx-sender, evidence-id: evidence-id }
      {
        evidence-hash: evidence-hash,
        description: description,
        submitted-at: stacks-block-height
      }
    )
    
    ;; Transition to voting phase if evidence period ended
    (if (>= stacks-block-height (get evidence-deadline dispute))
      (map-set disputes { dispute-id: dispute-id }
        (merge dispute { status: DISPUTE-VOTING-PHASE })
      )
      true
    )
    
    (ok evidence-id)
  )
)

;; Cast vote as arbitrator
(define-public (cast-vote (dispute-id uint) (vote uint) (reasoning (string-ascii 300)))
  (let (
        (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-NOT-FOUND))
        (assignment (unwrap! (map-get? dispute-assignments { dispute-id: dispute-id, arbitrator: tx-sender }) ERR-NOT-ARBITRATOR))
        (votes (unwrap! (map-get? dispute-votes { dispute-id: dispute-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get status dispute) DISPUTE-VOTING-PHASE) ERR-INVALID-PARAMS)
    (asserts! (<= stacks-block-height (get voting-deadline dispute)) ERR-INVALID-PARAMS)
    (asserts! (get assigned assignment) ERR-NOT-ARBITRATOR)
    (asserts! (not (get voted assignment)) ERR-ALREADY-VOTED)
    (asserts! (and (>= vote u1) (<= vote u4)) ERR-INVALID-PARAMS)
    
    ;; Record the vote
    (map-set dispute-assignments { dispute-id: dispute-id, arbitrator: tx-sender }
      (merge assignment { voted: true, vote: (some vote) })
    )
    
    ;; Update vote tallies
    (let (
          (new-votes (if (is-eq vote OUTCOME-FAVOR-CLIENT)
                       (merge votes { votes-client: (inc (get votes-client votes)), total-votes: (inc (get total-votes votes)) })
                       (if (is-eq vote OUTCOME-FAVOR-FREELANCER)
                         (merge votes { votes-freelancer: (inc (get votes-freelancer votes)), total-votes: (inc (get total-votes votes)) })
                         (merge votes { votes-split: (inc (get votes-split votes)), total-votes: (inc (get total-votes votes)) })
                       )
                     ))
        )
      (map-set dispute-votes { dispute-id: dispute-id } new-votes)
      
      ;; Check if we have enough votes to resolve
      (if (>= (get total-votes new-votes) (var-get min-arbitrators))
        (let (
              (resolution (calculate-majority-decision dispute-id))
            )
          (map-set disputes { dispute-id: dispute-id }
            (merge dispute {
              status: DISPUTE-RESOLVED,
              resolution: (some resolution),
              payment-split: (if (is-eq resolution OUTCOME-SPLIT-PAYMENT) (some u50) none),
              resolved-at: (some stacks-block-height)
            })
          )
        )
        true
      )
    )
    
    (ok true)
  )
)

;; Appeal a resolved dispute (either party)
(define-public (appeal-dispute (dispute-id uint) (appeal-reason (string-ascii 200)))
  (let (
        (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get status dispute) DISPUTE-RESOLVED) ERR-DISPUTE-CLOSED)
    (asserts! (or (is-eq tx-sender (get plaintiff dispute))
                  (is-eq tx-sender (get defendant dispute))) ERR-NOT-AUTHORIZED)
    (asserts! (<= stacks-block-height (+ (default-to u0 (get resolved-at dispute)) u720)) ERR-INVALID-PARAMS) ;; 5 days to appeal
    
    (map-set disputes { dispute-id: dispute-id }
      (merge dispute { status: DISPUTE-APPEALED })
    )
    
    (ok true)
  )
)

;; Deactivate arbitrator (self or admin)
(define-public (deactivate-arbitrator (arbitrator principal))
  (let (
        (arb (unwrap! (map-get? arbitrators { arbitrator: arbitrator }) ERR-NOT-FOUND))
      )
    (asserts! (or (is-eq tx-sender arbitrator) (is-eq tx-sender CONTRACT-OWNER)) ERR-NOT-AUTHORIZED)
    
    (map-set arbitrators { arbitrator: arbitrator }
      (merge arb { active: false })
    )
    
    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

(define-read-only (get-arbitrator (arbitrator principal))
  (map-get? arbitrators { arbitrator: arbitrator })
)

(define-read-only (get-dispute-assignment (dispute-id uint) (arbitrator principal))
  (map-get? dispute-assignments { dispute-id: dispute-id, arbitrator: arbitrator })
)

(define-read-only (get-evidence (dispute-id uint) (submitter principal) (evidence-id uint))
  (map-get? evidence-submissions { dispute-id: dispute-id, submitter: submitter, evidence-id: evidence-id })
)

(define-read-only (get-dispute-votes (dispute-id uint))
  (map-get? dispute-votes { dispute-id: dispute-id })
)

(define-read-only (get-contract-stats)
  {
    total-disputes: (var-get total-disputes),
    arbitrator-count: (var-get arbitrator-count),
    next-dispute-id: (var-get next-dispute-id),
    min-arbitrators: (var-get min-arbitrators)
  }
)

;; Administrative Functions

(define-public (set-min-arbitrators (new-min uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= new-min u1) (<= new-min u10)) ERR-INVALID-PARAMS)
    (var-set min-arbitrators new-min)
    (ok new-min)
  )
)
