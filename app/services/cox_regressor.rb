# app/services/cox_regressor.rb
#
# Модель Кокса (Cox proportional hazards) для survival-анализа.
#
# Цель — научить линейный предиктор β·x так, чтобы он ранжировал пациентов по
# мгновенному риску. Минимизируем отрицательный логарифм частичного правдоподобия
# с приближением Бреслоу (для совпадающих времён события):
#
#   ℓ(β) = Σ_g [ Σ_{i∈D_g} β·x_i  −  d_g · log Σ_{j∈R_g} exp(β·x_j) ]   + L2
#
# где D_g — события на времени t_g, R_g — risk set (все живые на t_g).
#
# В отличие от Ridge на log-времени, Cox корректно учитывает цензурированных
# пациентов: они вкладываются только в знаменатель (risk set), а не в числитель.
#
# Оптимизация — Adam (NLL строго выпуклая c L2, сходится за 100-300 итераций).
# Базовая функция риска по Бреслоу — для перевода risk score → дни.
class CoxRegressor
  attr_reader :weights, :baseline_survival, :n_iter, :converged, :final_loss

  MAX_ITER = 500
  TOL      = 1e-7
  LR       = 0.05

  def initialize(reg_param: 0.1)
    @reg_param = reg_param.to_f
  end

  # x_matrix: Numo::DFloat[n, p], times: Array<Float>, events: Array<Integer 0/1>
  def fit(x_matrix, times, events)
    n, p = x_matrix.shape
    raise ArgumentError, "Cox требует хотя бы одно наблюдаемое событие" if events.sum.zero?

    order = (0...n).sort_by { |i| -times[i].to_f }
    @x_sorted = Numo::DFloat[*order.map { |i| x_matrix[i, true].to_a }]
    @t_sorted = order.map { |i| times[i].to_f }
    @e_sorted = order.map { |i| events[i].to_i }
    @groups   = compute_groups

    @weights = Numo::DFloat.zeros(p)

    m  = Numo::DFloat.zeros(p)
    vv = Numo::DFloat.zeros(p)
    b1, b2, eps = 0.9, 0.999, 1e-8

    @converged = false
    prev_loss  = Float::INFINITY

    MAX_ITER.times do |t|
      grad, loss = grad_and_loss(@weights)

      m  = b1 * m  + (1 - b1) * grad
      vv = b2 * vv + (1 - b2) * grad * grad
      m_hat = m  / (1 - b1**(t + 1))
      v_hat = vv / (1 - b2**(t + 1))

      @weights = @weights - LR * m_hat / (Numo::NMath.sqrt(v_hat) + eps)
      @n_iter  = t + 1
      @final_loss = loss

      if t > 20 && (prev_loss - loss).abs < TOL
        @converged = true
        break
      end
      prev_loss = loss
    end

    @baseline_survival = compute_baseline_survival
    self
  end

  # Линейный предиктор (log hazard ratio относительно базовой). Бо́льшее значение —
  # выше мгновенный риск, короче ожидаемая выживаемость.
  def predict_risk(x_matrix)
    x_matrix.dot(@weights).to_a
  end

  # Медиана выживаемости пациента: наименьшее t, где S(t|x) ≤ 0.5,
  # S(t|x) = S₀(t)^exp(risk).
  def median_survival_for(risk)
    return 0.0 if @baseline_survival.empty?

    er = Math.exp(clamp_risk(risk))
    @baseline_survival.each do |pt|
      s_x = [ pt["s0"], 1e-12 ].max**er
      return pt["time"] if s_x <= 0.5
    end
    @baseline_survival.last["time"]
  end

  private

  # Группируем индексы по совпадающим временам (sorted desc).
  # Каждая группа: { time, end_idx (последний sorted-индекс), events_idx (массив) }.
  def compute_groups
    groups = []
    n = @t_sorted.length
    i = 0
    while i < n
      j = i
      events_idx = []
      while j < n && @t_sorted[j] == @t_sorted[i]
        events_idx << j if @e_sorted[j] == 1
        j += 1
      end
      groups << { time: @t_sorted[i], end_idx: j - 1, events_idx: events_idx }
      i = j
    end
    groups
  end

  # Считает grad и -log L (с L2). Использует кумулятивные суммы по risk-set
  # за один проход — поскольку отсортировано по убыванию t, R(t_g) = всё, что
  # просмотрено к концу группы g.
  def grad_and_loss(beta)
    n, p = @x_sorted.shape

    eta     = @x_sorted.dot(beta)
    eta_max = eta.max.to_f
    exp_eta = Numo::NMath.exp(eta - eta_max)  # log-sum-exp устойчивость

    log_lik = 0.0
    grad    = Numo::DFloat.zeros(p)

    cum_s0 = 0.0
    cum_s1 = Numo::DFloat.zeros(p)
    cursor = 0

    @groups.each do |g|
      (cursor..g[:end_idx]).each do |k|
        ek = exp_eta[k]
        cum_s0 += ek
        cum_s1 = cum_s1 + @x_sorted[k, true] * ek
      end
      cursor = g[:end_idx] + 1

      e_idx = g[:events_idx]
      next if e_idx.empty?

      d = e_idx.length
      sum_eta_e    = e_idx.sum { |k| eta[k] }
      log_risk_sum = Math.log(cum_s0) + eta_max
      log_lik     += sum_eta_e - d * log_risk_sum

      sum_x_e = Numo::DFloat.zeros(p)
      e_idx.each { |k| sum_x_e = sum_x_e + @x_sorted[k, true] }
      mean_x = cum_s1 / cum_s0  # exp(eta_max) сокращается в числителе/знаменателе
      grad   = grad - sum_x_e + mean_x * d
    end

    nll = -log_lik + 0.5 * @reg_param * beta.dot(beta).to_f
    grad = grad + beta * @reg_param

    [ grad, nll ]
  end

  # Базовая выживаемость по Бреслоу:
  #   H₀(t) = Σ_{t_g ≤ t} d_g / Σ_{j∈R_g} exp(β·x_j)
  #   S₀(t) = exp(−H₀(t))
  # Возвращает массив точек по возрастанию времени, готовый к JSON-сериализации.
  def compute_baseline_survival
    eta     = @x_sorted.dot(@weights)
    eta_max = eta.max.to_f
    exp_eta = Numo::NMath.exp(eta - eta_max)

    cum_s0 = 0.0
    cursor = 0
    incs   = []

    @groups.each do |g|
      (cursor..g[:end_idx]).each { |k| cum_s0 += exp_eta[k] }
      cursor = g[:end_idx] + 1

      e_idx = g[:events_idx]
      next if e_idx.empty?

      s0_real = cum_s0 * Math.exp(eta_max)
      incs << { time: g[:time], inc: e_idx.length / s0_real }
    end

    incs.reverse!  # из desc-порядка времени обратно в asc

    cum_h  = 0.0
    points = [ { "time" => 0.0, "h0_cum" => 0.0, "s0" => 1.0 } ]
    incs.each do |row|
      cum_h += row[:inc]
      points << { "time" => row[:time].round(2), "h0_cum" => cum_h.round(6), "s0" => Math.exp(-cum_h).round(6) }
    end
    points
  end

  def clamp_risk(r)
    # exp(±50) уже даёт диапазон, более чем покрывающий любые разумные риск-скоры.
    r.clamp(-50.0, 50.0)
  end
end
