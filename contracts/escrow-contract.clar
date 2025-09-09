;; escrow-contract
;; Smart contract to hold funds until project completion

;; Constants and Error Codes
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u800))
(define-constant ERR-NOT-FOUND (err u801))
(define-constant ERR-INVALID-PARAMS (err u802))
(define-constant ERR-ESCROW-FINALIZED (err u803))
(define-constant ERR-INSUFFICIENT-FUNDS (err u804))
(define-constant ERR-DEADLINE-PASSED (err u805))
(define-constant ERR-WORK-NOT-SUBMITTED (err u806))
(define-constant ERR-ALREADY-APPROVED (err u807))

;; Escrow Status Constants
(define-constant STATUS-CREATED u1)
(define-constant STATUS-FUNDED u2)
(define-constant STATUS-WORK-SUBMITTED u3)
(define-constant STATUS-APPROVED u4)
(define-constant STATUS-DISPUTED u5)
(define-constant STATUS-RESOLVED u6)
(define-constant STATUS-CANCELLED u7)

;; Data Variables
(define-data-var next-escrow-id uint u1)
(define-data-var total-escrows uint u0)
(define-data-var total-value-locked uint u0)
(define-data-var platform-fee-bps uint u250) ;; 2.5% fee

;; Data Maps
(define-map escrows
  { escrow-id: uint }
  {
    client: principal,
    freelancer: principal,
    amount: uint,
    deadline: uint,
    status: uint,
    project-description: (string-ascii 200),
    deliverable-hash: (optional (string-ascii 64)),
    created-at: uint,
    funded-at: (optional uint),
    completed-at: (optional uint)
  }
)

(define-map milestones
  { escrow-id: uint, milestone-id: uint }
  {
    description: (string-ascii 100),
    amount: uint,
    deadline: uint,
    completed: bool,
    approved: bool
  }
)

(define-map user-stats
  { user: principal }
  {
    escrows-created: uint,
    escrows-completed: uint,
    total-earned: uint,
    total-spent: uint,
    reputation-score: uint
  }
)

(define-map escrow-funds
  { escrow-id: uint }
  { deposited: uint, released: uint, remaining: uint }
)

;; Private Helper Functions
(define-private (inc (x uint)) (+ x u1))

(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

(define-private (is-deadline-passed (deadline uint))
  (> stacks-block-height deadline)
)

(define-private (update-user-stats-created (user principal) (amount uint))
  (let (
        (stats (default-to { escrows-created: u0, escrows-completed: u0, total-earned: u0, total-spent: u0, reputation-score: u50 }
                           (map-get? user-stats { user: user })))
      )
    (map-set user-stats { user: user }
      {
        escrows-created: (inc (get escrows-created stats)),
        escrows-completed: (get escrows-completed stats),
        total-earned: (get total-earned stats),
        total-spent: (+ (get total-spent stats) amount),
        reputation-score: (get reputation-score stats)
      }
    )
  )
)

(define-private (update-user-stats-completed (user principal) (amount uint))
  (let (
        (stats (default-to { escrows-created: u0, escrows-completed: u0, total-earned: u0, total-spent: u0, reputation-score: u50 }
                           (map-get? user-stats { user: user })))
      )
    (map-set user-stats { user: user }
      {
        escrows-created: (get escrows-created stats),
        escrows-completed: (inc (get escrows-completed stats)),
        total-earned: (+ (get total-earned stats) amount),
        total-spent: (get total-spent stats),
        reputation-score: (if (< (+ (get reputation-score stats) u5) u100) (+ (get reputation-score stats) u5) u100)
      }
    )
  )
)

;; Public Functions

;; Create a new escrow contract
(define-public (create-escrow
  (freelancer principal)
  (amount uint)
  (deadline-days uint)
  (project-description (string-ascii 200))
  )
  (let (
        (escrow-id (var-get next-escrow-id))
        (deadline (+ stacks-block-height (* deadline-days u144)))
      )
    (asserts! (> amount u0) ERR-INVALID-PARAMS)
    (asserts! (> deadline-days u0) ERR-INVALID-PARAMS)
    (asserts! (not (is-eq tx-sender freelancer)) ERR-INVALID-PARAMS)
    
    ;; Create escrow record
    (map-set escrows { escrow-id: escrow-id }
      {
        client: tx-sender,
        freelancer: freelancer,
        amount: amount,
        deadline: deadline,
        status: STATUS-CREATED,
        project-description: project-description,
        deliverable-hash: none,
        created-at: stacks-block-height,
        funded-at: none,
        completed-at: none
      }
    )
    
    ;; Initialize fund tracking
    (map-set escrow-funds { escrow-id: escrow-id }
      { deposited: u0, released: u0, remaining: u0 }
    )
    
    ;; Update statistics
    (update-user-stats-created tx-sender amount)
    (var-set next-escrow-id (inc escrow-id))
    (var-set total-escrows (inc (var-get total-escrows)))
    
    (ok escrow-id)
  )
)

;; Fund the escrow (client only)
(define-public (fund-escrow (escrow-id uint) (payment uint))
  (let (
        (escrow (unwrap! (map-get? escrows { escrow-id: escrow-id }) ERR-NOT-FOUND))
        (funds (unwrap! (map-get? escrow-funds { escrow-id: escrow-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get client escrow) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) STATUS-CREATED) ERR-ESCROW-FINALIZED)
    (asserts! (>= payment (get amount escrow)) ERR-INSUFFICIENT-FUNDS)
    
    ;; Update escrow status
    (map-set escrows { escrow-id: escrow-id }
      (merge escrow { 
        status: STATUS-FUNDED,
        funded-at: (some stacks-block-height)
      })
    )
    
    ;; Update fund tracking
    (map-set escrow-funds { escrow-id: escrow-id }
      (merge funds { 
        deposited: payment,
        remaining: payment
      })
    )
    
    (var-set total-value-locked (+ (var-get total-value-locked) payment))
    (ok true)
  )
)

;; Submit deliverable (freelancer only)
(define-public (submit-deliverable
  (escrow-id uint)
  (deliverable-hash (string-ascii 64))
  (delivery-note (string-ascii 200))
  )
  (let (
        (escrow (unwrap! (map-get? escrows { escrow-id: escrow-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get freelancer escrow) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) STATUS-FUNDED) ERR-INVALID-PARAMS)
    (asserts! (not (is-deadline-passed (get deadline escrow))) ERR-DEADLINE-PASSED)
    
    (map-set escrows { escrow-id: escrow-id }
      (merge escrow {
        status: STATUS-WORK-SUBMITTED,
        deliverable-hash: (some deliverable-hash)
      })
    )
    
    (ok true)
  )
)

;; Approve work and release payment (client only)
(define-public (approve-release (escrow-id uint) (approved bool))
  (let (
        (escrow (unwrap! (map-get? escrows { escrow-id: escrow-id }) ERR-NOT-FOUND))
        (funds (unwrap! (map-get? escrow-funds { escrow-id: escrow-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get client escrow) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) STATUS-WORK-SUBMITTED) ERR-WORK-NOT-SUBMITTED)
    
    (if approved
      (begin
        ;; Approve and release payment
        (let (
              (net-amount (- (get remaining funds) (calculate-fee (get remaining funds))))
            )
          (map-set escrows { escrow-id: escrow-id }
            (merge escrow {
              status: STATUS-APPROVED,
              completed-at: (some stacks-block-height)
            })
          )
          
          (map-set escrow-funds { escrow-id: escrow-id }
            (merge funds {
              released: (get remaining funds),
              remaining: u0
            })
          )
          
          ;; Update statistics
          (update-user-stats-completed (get freelancer escrow) net-amount)
          (var-set total-value-locked (- (var-get total-value-locked) (get remaining funds)))
          (ok net-amount)
        )
      )
      (begin
        ;; Reject work - initiate dispute
        (map-set escrows { escrow-id: escrow-id }
          (merge escrow { status: STATUS-DISPUTED })
        )
        (ok u0)
      )
    )
  )
)

;; Emergency release after deadline (freelancer only)
(define-public (emergency-release (escrow-id uint))
  (let (
        (escrow (unwrap! (map-get? escrows { escrow-id: escrow-id }) ERR-NOT-FOUND))
        (funds (unwrap! (map-get? escrow-funds { escrow-id: escrow-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get freelancer escrow) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) STATUS-WORK-SUBMITTED) ERR-WORK-NOT-SUBMITTED)
    (asserts! (is-deadline-passed (+ (get deadline escrow) u1440)) ERR-INVALID-PARAMS) ;; 10 days past deadline
    
    (let (
          (net-amount (- (get remaining funds) (calculate-fee (get remaining funds))))
        )
      (map-set escrows { escrow-id: escrow-id }
        (merge escrow {
          status: STATUS-RESOLVED,
          completed-at: (some stacks-block-height)
        })
      )
      
      (map-set escrow-funds { escrow-id: escrow-id }
        (merge funds {
          released: (get remaining funds),
          remaining: u0
        })
      )
      
      (update-user-stats-completed tx-sender net-amount)
      (var-set total-value-locked (- (var-get total-value-locked) (get remaining funds)))
      (ok net-amount)
    )
  )
)

;; Cancel escrow (client only, before funding)
(define-public (cancel-escrow (escrow-id uint))
  (let (
        (escrow (unwrap! (map-get? escrows { escrow-id: escrow-id }) ERR-NOT-FOUND))
      )
    (asserts! (is-eq (get client escrow) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status escrow) STATUS-CREATED) ERR-ESCROW-FINALIZED)
    
    (map-set escrows { escrow-id: escrow-id }
      (merge escrow { status: STATUS-CANCELLED })
    )
    
    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-escrow (escrow-id uint))
  (map-get? escrows { escrow-id: escrow-id })
)

(define-read-only (get-escrow-funds (escrow-id uint))
  (map-get? escrow-funds { escrow-id: escrow-id })
)

(define-read-only (get-user-stats (user principal))
  (map-get? user-stats { user: user })
)

(define-read-only (get-milestone (escrow-id uint) (milestone-id uint))
  (map-get? milestones { escrow-id: escrow-id, milestone-id: milestone-id })
)

(define-read-only (get-contract-stats)
  {
    total-escrows: (var-get total-escrows),
    total-value-locked: (var-get total-value-locked),
    next-escrow-id: (var-get next-escrow-id),
    platform-fee-bps: (var-get platform-fee-bps)
  }
)

;; Administrative Functions (Owner Only)

(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-bps u1000) ERR-INVALID-PARAMS) ;; Max 10%
    (var-set platform-fee-bps new-fee-bps)
    (ok new-fee-bps)
  )
)
