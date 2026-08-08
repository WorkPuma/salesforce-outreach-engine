import { LightningElement, api, wire, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { refreshApex } from "@salesforce/apex";
import {
  publish,
  subscribe,
  unsubscribe,
  MessageContext,
  APPLICATION_SCOPE
} from "lightning/messageService";
import PatientOutreachState from "@salesforce/messageChannel/PatientOutreachState__c";
import getPatientWorkspace from "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace";
import enhanceRationale from "@salesforce/apex/OutreachWorkbenchController.enhanceRationale";
import getRecentEvents from "@salesforce/apex/OutreachWorkbenchController.getRecentEvents";
import getAppointmentHistory from "@salesforce/apex/OutreachWorkbenchController.getAppointmentHistory";
import recordSoftHold from "@salesforce/apex/OutreachWorkbenchController.recordSoftHold";
import silenceNeed from "@salesforce/apex/OutreachWorkbenchController.silenceNeed";
import unsilenceNeed from "@salesforce/apex/OutreachWorkbenchController.unsilenceNeed";
import extendNeedSnooze from "@salesforce/apex/OutreachWorkbenchController.extendNeedSnooze";

const PATH_STAGES = [
  { api: "STAT", label: "Urgent" },
  { api: "Urgent", label: "Important" },
  { api: "Routine", label: "Routine" }
];

const PRIORITY_LABELS = {
  STAT: "Urgent",
  URGENT: "Important",
  ROUTINE: "Routine"
};

const PARENT_KEYS = new Set([
  "AWV",
  "OFF_CADENCE",
  "NO_NEXT",
  "UNENGAGED",
  "URGENT_REFERRAL",
  "MDDO",
  "DISCHARGE_TCM",
  "ADMISSION_TOUCHBASE"
]);

export default class PatientOutreachActions extends LightningElement {
  @api recordId;
  workspace;
  events = [];
  historyViewMode = "chrono"; // chrono | activity
  expandedActivityKeys = [];
  showAllCareGaps = false;
  showAppointments = false;
  appointmentEvents = [];
  silenceReason = "";
  overrideNeedId;
  overrideUntil;
  workspaceWire;
  eventsWire;
  error;
  isLoading = true;
  softHoldDoneFor;
  selectedNeedIds = [];
  acknowledgedNeedIds = [];
  silenceNeedId;
  silenceExpiry;
  showSilenceForm = false;
  showExtendDialog = false;
  extendNeedId;
  extendUntil;
  @track timelineExpanded = false;
  subscription = null;
  _messageContext;

  @wire(MessageContext) messageContext;

  renderedCallback() {
    this.subscribeToChannel();
  }

  disconnectedCallback() {
    this.unsubscribeFromChannel();
  }

  @wire(getPatientWorkspace, { recordId: "$recordId" })
  wiredWorkspace(result) {
    this.workspaceWire = result;
    if (result.data !== undefined) {
      this.workspace = result.data
        ? {
            ...result.data,
            needs: result.data.needs || []
          }
        : null;
      this.error = undefined;
      this.isLoading = false;
      this.bootstrapSelectedNeeds();
      this.publishNeedState();
      this.maybeSoftHold();
      this.enhanceSituationDescription();
    } else if (result.error) {
      this.error = this.message(
        result.error,
        "Unable to load outreach workspace."
      );
      this.isLoading = false;
    }
  }

  @wire(getRecentEvents, { recordId: "$recordId", rowLimit: 50 })
  wiredEvents(result) {
    this.eventsWire = result;
    if (result.data) {
      this.events = result.data;
    } else if (result.error) {
      this.error = this.message(
        result.error,
        "Unable to load outreach history."
      );
    }
  }

  get hasWorkspace() {
    return !!this.workspace;
  }
  get isCommentOnlyMode() {
    return !!this.workspace?.commentOnlyMode;
  }
  get activeNeeds() {
    return (this.workspace?.needs || []).filter(
      (n) =>
        n.state !== "Superseded" &&
        n.state !== "Shadow" &&
        n.state !== "Silenced" &&
        n.state !== "Resolved"
    );
  }
  get addressedNeeds() {
    return (this.workspace?.needs || []).filter(
      (n) => (n.state || "").toUpperCase() === "RESOLVED"
    );
  }
  get silencedNeeds() {
    return (this.workspace?.needs || []).filter((n) => n.state === "Silenced");
  }
  get hasSilencedNeeds() {
    return this.silencedNeeds.length > 0;
  }
  /** Parent care items only — Unengaged flavors hide when Off Cadence is present. */
  get parentCareNeeds() {
    const active = this.activeNeeds;
    const hasOffCadence = active.some((n) => this.parentKey(n) === "OFF_CADENCE");
    const byParent = new Map();
    for (const need of active) {
      const key = this.parentKey(need);
      if (!PARENT_KEYS.has(key)) continue;
      if (key === "UNENGAGED" && hasOffCadence) continue;
      if (key === "INACTIVE") continue;
      const prior = byParent.get(key);
      if (!prior || Number(need.points || 0) > Number(prior.points || 0)) {
        byParent.set(key, need);
      }
    }
    // Prefer stable order: Urgent parents first by points
    return [...byParent.values()].sort(
      (a, b) => Number(b.points || 0) - Number(a.points || 0)
    );
  }
  get totalCareGapCount() {
    const activeParents = new Set(
      this.parentCareNeeds.map((n) => this.parentKey(n))
    );
    const addressedParents = new Set();
    for (const need of this.addressedNeeds) {
      const key = this.parentKey(need);
      if (!PARENT_KEYS.has(key) || activeParents.has(key) || key === "INACTIVE")
        continue;
      addressedParents.add(key);
    }
    return activeParents.size + addressedParents.size;
  }
  get hasNeeds() {
    return this.totalCareGapCount > 0;
  }
  get needCount() {
    return this.totalCareGapCount;
  }
  get showAllGapsLabel() {
    const n = this.hiddenCareGapCount;
    return n > 0 ? `Show all (${n} more)` : "Show all";
  }
  get chronoViewClass() {
    return (
      "history-view-toggle__btn" +
      (this.isChronoHistory ? " history-view-toggle__btn_active" : "")
    );
  }
  get activityViewClass() {
    return (
      "history-view-toggle__btn" +
      (this.isActivityHistory ? " history-view-toggle__btn_active" : "")
    );
  }
  get careGapCards() {
    const CARD_LIMIT = 6;
    const build = (need, addressed) => {
      const selected = !addressed && this.selectedNeedIds.includes(need.id);
      const force = need.forceAcknowledge === true;
      const acked = this.acknowledgedNeedIds.includes(need.id);
      const intensity = this.intensityClass(need.points, need.priority);
      const priorityLabel = this.priorityLabel(need.priority);
      const parent = this.parentKey(need);
      const isSnoozed = (need.state || "").toUpperCase() === "SNOOZED";
      return {
        ...need,
        title: this.parentTitle(parent, need.displayLabel || need.needType),
        cardClass:
          "care-gap" +
          (addressed ? " care-gap_addressed" : "") +
          (selected ? " care-gap_selected" : "") +
          (force && !acked && !addressed ? " care-gap_force" : "") +
          (isSnoozed ? " care-gap_snoozed" : "") +
          " " +
          intensity,
        badgeClass: "care-gap__badge " + intensity,
        accentClass: "care-gap__accent " + intensity,
        iconName: this.priorityIcon(need.priority),
        priorityLabel: addressed ? "Addressed" : priorityLabel,
        selected,
        force: force && !addressed,
        acked,
        isSnoozed,
        isAddressed: addressed,
        selectDisabled: addressed || this.isCommentOnlyMode,
        showOverrideInline: isSnoozed && this.overrideNeedId === need.id,
        snoozeUntilLabel: isSnoozed
          ? this.formatDateOnly(need.snoozeUntil)
          : "",
        attemptLabel: need.attemptCount
          ? `${need.attemptCount} attempts`
          : "No attempts yet",
        dueLabel:
          need.schedulePhrase ||
          need.scheduleStatusLabel ||
          (need.nextActionDate ? "Due date set" : "No due date"),
        whyText: need.actionDescription || need.businessSummary || ""
      };
    };
    const active = this.parentCareNeeds.map((n) => build(n, false));
    // Addressed parents (resolved) for greying — de-dupe by parent key vs active.
    const activeParents = new Set(active.map((n) => this.parentKey(n)));
    const addressed = [];
    const seenAddressed = new Set();
    for (const need of this.addressedNeeds) {
      const key = this.parentKey(need);
      if (!PARENT_KEYS.has(key) || activeParents.has(key)) continue;
      if (key === "INACTIVE" || seenAddressed.has(key)) continue;
      seenAddressed.add(key);
      addressed.push(build(need, true));
    }
    const all = [...active, ...addressed];
    if (this.showAllCareGaps || all.length <= CARD_LIMIT) return all;
    return all.slice(0, CARD_LIMIT);
  }
  get hasMoreCareGaps() {
    return this.totalCareGapCount > 6 && !this.showAllCareGaps;
  }
  get hiddenCareGapCount() {
    return Math.max(0, this.totalCareGapCount - 6);
  }
  showAllGaps() {
    this.showAllCareGaps = true;
  }

  get pathStages() {
    const current = (this.workspace?.priority || "Routine").toUpperCase();
    return PATH_STAGES.map((stage) => ({
      key: stage.api,
      label: stage.label,
      className:
        "urgency-path__stage " +
        this.intensityClass(null, stage.api) +
        (stage.api.toUpperCase() === current
          ? " urgency-path__stage_active"
          : "")
    }));
  }
  /**
   * Pending needs ordered by the same weighting as Apex (priority, then points).
   * Do not special-case rule families here — adjust Outreach_Rule__mdt / RulesEngine points.
   */
  priorityRank(priority) {
    const p = (priority || "").toUpperCase();
    if (p === "STAT") return 0;
    if (p === "URGENT") return 1;
    return 2;
  }

  pendingCareNeeds() {
    const needs = this.workspace?.needs || [];
    return needs
      .filter(
        (n) =>
          n &&
          n.state !== "Superseded" &&
          n.state !== "Shadow" &&
          n.state !== "Silenced" &&
          n.state !== "Resolved"
      )
      .slice()
      .sort((a, b) => {
        const rank = this.priorityRank(a.priority) - this.priorityRank(b.priority);
        if (rank !== 0) return rank;
        return (b.points || 0) - (a.points || 0);
      });
  }

  escapeHtml(value) {
    return String(value || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  formatNumericScheduleDate(isoDate) {
    if (!isoDate) return "";
    const d = new Date(`${isoDate}T00:00:00`);
    if (Number.isNaN(d.getTime())) return "";
    return d.toLocaleDateString("en-US", {
      month: "numeric",
      day: "numeric",
      year: "numeric"
    });
  }

  shortRiskTierLabel() {
    const raw = (this.workspace?.riskTier || "").trim();
    if (!raw) return "";
    return raw.replace(/\s+Risk$/i, "").trim();
  }

  scheduleNoteForNeed(need) {
    const bound = (need?.scheduleBoundType || "").trim().toUpperCase();
    if (bound === "ANYTIME_AFTER" && need.scheduleEarliest) {
      const earliest = new Date(`${need.scheduleEarliest}T00:00:00`);
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      if (!Number.isNaN(earliest.getTime()) && earliest <= today) {
        return "eligible now";
      }
      if (!Number.isNaN(earliest.getTime())) {
        return `anytime after ${earliest.toLocaleDateString("en-US", {
          month: "long",
          day: "numeric",
          year: "numeric"
        })}`;
      }
    }
    if (need?.schedulePhrase) return need.schedulePhrase;
    if (need?.scheduleStatusLabel) return need.scheduleStatusLabel;
    return "";
  }

  actionBaseForNeed(need) {
    return (
      need?.recommendedAction ||
      need?.displayLabel ||
      need?.needType ||
      "Review care gap"
    )
      .trim()
      .replace(/\.+$/, "");
  }

  actionLabelForNeed(need) {
    const base = this.actionBaseForNeed(need);
    const bound = (need?.scheduleBoundType || "").trim().toUpperCase();
    if (bound === "ON_OR_BEFORE" && need.scheduleLatest) {
      const dateLabel = this.formatNumericScheduleDate(need.scheduleLatest);
      const tier = this.shortRiskTierLabel();
      const tierSuffix = tier ? ` [Risk Tier: ${tier}]` : "";
      return dateLabel
        ? `${base} before ${dateLabel}${tierSuffix}`
        : base;
    }
    const note = this.scheduleNoteForNeed(need);
    // Timing comes from RulesEngine schedule fields on the need — any future rule can set them.
    return note ? `${base}. (${note})` : base;
  }

  actionHtmlForNeed(need) {
    const base = this.escapeHtml(this.actionBaseForNeed(need));
    const bound = (need?.scheduleBoundType || "").trim().toUpperCase();
    if (bound === "ON_OR_BEFORE" && need.scheduleLatest) {
      const dateLabel = this.formatNumericScheduleDate(need.scheduleLatest);
      const tier = this.shortRiskTierLabel();
      const tierSuffix = tier
        ? ` [Risk Tier: ${this.escapeHtml(tier)}]`
        : "";
      if (!dateLabel) return base;
      return `${base} before <strong>${this.escapeHtml(dateLabel)}</strong>${tierSuffix}`;
    }
    const note = this.scheduleNoteForNeed(need);
    if (!note) return base;
    return `${base}. (${this.escapeHtml(note)})`;
  }

  factPhraseForNeed(need) {
    const phrase = (need?.situationPhrase || "").trim();
    if (phrase) return phrase.replace(/\.+$/, "");
    const label = (need?.displayLabel || need?.friendlyLabel || need?.needType || "an outreach need").trim();
    return label;
  }

  get situationStatement() {
    const pending = this.pendingCareNeeds();
    let genai = (this.workspace?.rationale || "").trim();
    genai = genai.replace(/\s*Next step:\s*.+$/i, "").trim();

    // Multi-gap: build statement from weighted needs so new rules appear automatically.
    if (pending.length > 1) {
      const facts = pending.map((n) => this.factPhraseForNeed(n));
      if (facts.length === 2) {
        return `The patient has ${facts[0]} and ${facts[1]}.`;
      }
      const head = facts.slice(0, -1).join(", ");
      return `The patient has ${head}, and ${facts[facts.length - 1]}.`;
    }
    if (genai) return genai;
    if (pending.length === 1) {
      return `The patient has ${this.factPhraseForNeed(pending[0])}.`;
    }
    return "";
  }

  get situationActionItems() {
    const items = [];
    const seen = new Set();
    for (const need of this.pendingCareNeeds()) {
      const label = this.actionLabelForNeed(need);
      const norm = label.toLowerCase();
      if (!label || seen.has(norm)) continue;
      seen.add(norm);
      items.push({
        key: need.id || `need-${items.length}`,
        label,
        html: this.actionHtmlForNeed(need)
      });
    }
    return items;
  }

  get situationHtml() {
    const statement = this.situationStatement;
    const actions = this.situationActionItems;
    if (!statement && !actions.length) return "";
    let html = "";
    if (statement) {
      html += `<p>${this.escapeHtml(statement)}</p>`;
    }
    if (actions.length) {
      html += "<p><strong>Next step</strong></p><ul>";
      for (const item of actions) {
        html += `<li>${item.html}</li>`;
      }
      html += "</ul>";
    }
    return html;
  }

  get hasSituationHtml() {
    return Boolean(this.situationHtml);
  }

  get hasSituationActions() {
    return this.situationActionItems.length > 0;
  }

  /** Kept for tests that still assert on .oi-situation text content. */
  get situationDescription() {
    const statement = this.situationStatement;
    const actions = this.situationActionItems.map((i) => i.label).join(" ");
    return [statement, actions].filter(Boolean).join(" ");
  }

  get recommendedActionText() {
    return (
      this.workspace?.recommendedAction ||
      this.workspace?.nextAction ||
      "Review outreach"
    );
  }
  get shellClass() {
    return (
      "oi-shell " +
      this.intensityClass(this.workspace?.points, this.workspace?.priority)
    );
  }
  get heroAccentClass() {
    return (
      "oi-shell__accent " +
      this.intensityClass(this.workspace?.points, this.workspace?.priority)
    );
  }
  get filteredHistoryEvents() {
    const outreach = (this.events || []).filter(
      (e) => (e.eventType || "") !== "Reviewed Outreach"
    );
    if (!this.showAppointments) return outreach;
    const appts = this.appointmentEvents || [];
    return [...outreach, ...appts];
  }
  /** Chronological sessions: events that share actor+type+outcome+minute. */
  get chronoSessions() {
    const events = [...this.filteredHistoryEvents].sort(
      (a, b) => new Date(b.eventAt) - new Date(a.eventAt)
    );
    const sessions = [];
    const keyOf = (e) => {
      const when = e.eventAt ? new Date(e.eventAt) : null;
      const bucket = when
        ? `${when.getFullYear()}-${when.getMonth()}-${when.getDate()} ${when.getHours()}:${when.getMinutes()}`
        : "unknown";
      return [
        bucket,
        e.actorName || "",
        e.eventType || "",
        e.outcome || "",
        e.channel || ""
      ].join("|");
    };
    const byKey = new Map();
    for (const event of events) {
      const key = keyOf(event);
      if (!byKey.has(key)) {
        const comment = (event.detail || "").trim();
        const row = {
          key,
          whenLabel: this.formatWhen(event.eventAt),
          eventAt: event.eventAt,
          actorName: event.actorName,
          eventType: event.eventType,
          outcome: event.outcome,
          summaryText: event.summary || event.outcome || event.eventType,
          statusLabel:
            event.sourceKind === "appointment"
              ? event.eventType || event.careItemLabel
              : event.careItemLabel || "Outreach activity",
          statusDotClass: this.historyStatusDotClass(event.careItemKey),
          statusTextClass: this.historyStatusTextClass(event.careItemKey),
          commentText: this.truncateComment(comment, 80),
          commentFull: comment,
          hasComment: !!comment,
          subjects: [],
          subjectLabel: ""
        };
        byKey.set(key, row);
        sessions.push(row);
      }
      const row = byKey.get(key);
      const label = event.careItemLabel || event.ruleId || "Care item";
      if (!row.subjects.includes(label)) row.subjects.push(label);
    }
    for (const row of sessions) {
      row.subjectLabel = row.subjects.join(" · ");
      if (row.subjects.length > 1) {
        row.summaryText = `${row.summaryText} (${row.subjects.length} care items)`;
      }
    }
    return sessions;
  }
  truncateComment(text, maxLen) {
    if (!text) return "";
    if (text.length <= maxLen) return text;
    return text.slice(0, maxLen - 1) + "…";
  }
  async handleShowAppointments(event) {
    this.showAppointments = event.target.checked === true;
    if (this.showAppointments && !(this.appointmentEvents || []).length) {
      await this.loadAppointmentHistory();
    }
  }
  async loadAppointmentHistory() {
    if (!this.recordId) return;
    try {
      this.appointmentEvents =
        (await getAppointmentHistory({
          recordId: this.recordId,
          rowLimit: 40
        })) || [];
    } catch (e) {
      this.showError(e, "Unable to load appointment history.");
      this.appointmentEvents = [];
    }
  }
  get activityGroups() {
    const byKey = new Map();
    for (const event of this.filteredHistoryEvents) {
      let key =
        event.careItemKey ||
        this.parentKey({ ruleId: event.ruleId, needType: event.ruleId }) ||
        "";
      if (!key || key === "OTHER") key = "ACTIVITY";
      // INACTIVE stays in timeline history, but never becomes an outreach care-gap card
      // (PARENT_KEYS / parentCareNeeds still exclude it).
      if (!byKey.has(key)) {
        byKey.set(key, {
          key,
          label: event.careItemLabel || this.parentTitle(key, "Outreach activity"),
          statusDotClass: this.historyStatusDotClass(key),
          expanded: this.expandedActivityKeys.includes(key),
          events: [],
          countLabel: "",
          lastSeenLabel: ""
        });
      }
      byKey.get(key).events.push(event);
    }
    return [...byKey.values()]
      .map((g) => {
        const events = [...g.events]
          .sort((a, b) => new Date(b.eventAt) - new Date(a.eventAt))
          .map((event) => ({
            ...event,
            whenLabel: this.formatWhen(event.eventAt),
            summaryText:
              event.summary ||
              event.outcome ||
              event.eventType ||
              "Outreach update"
          }));
        return {
          ...g,
          events,
          countLabel: `${events.length} update${events.length === 1 ? "" : "s"}`,
          lastSeenLabel: events[0] ? this.formatWhen(events[0].eventAt) : "",
          chevronIcon: g.expanded ? "utility:chevrondown" : "utility:chevronright"
        };
      })
      .sort((a, b) => a.label.localeCompare(b.label));
  }
  get isChronoHistory() {
    return this.historyViewMode !== "activity";
  }
  get isActivityHistory() {
    return this.historyViewMode === "activity";
  }
  get historyModeLabel() {
    return this.isActivityHistory ? "Activity view" : "Compact view";
  }
  setHistoryChrono() {
    this.historyViewMode = "chrono";
  }
  setHistoryActivity() {
    this.historyViewMode = "activity";
  }
  toggleActivityGroup(event) {
    const key = event.currentTarget.dataset.key;
    if (!key) return;
    if (this.expandedActivityKeys.includes(key)) {
      this.expandedActivityKeys = this.expandedActivityKeys.filter((k) => k !== key);
    } else {
      this.expandedActivityKeys = [...this.expandedActivityKeys, key];
    }
  }
  historyStatusDotClass(careItemKey) {
    const k = (careItemKey || "").toUpperCase();
    if (k.includes("APPOINTMENT")) return "hist-dot hist-dot_appt";
    if (k.includes("NO_NEXT")) return "hist-dot hist-dot_nonext";
    if (k.includes("OFF_CADENCE")) return "hist-dot hist-dot_offcadence";
    if (k.includes("AWV")) return "hist-dot hist-dot_awv";
    if (k.includes("INACTIVE")) return "hist-dot hist-dot_inactive";
    if (k.includes("UNENGAGED")) return "hist-dot hist-dot_unengaged";
    return "hist-dot hist-dot_default";
  }
  historyStatusTextClass(careItemKey) {
    const k = (careItemKey || "").toUpperCase();
    if (k.includes("APPOINTMENT")) return "hist-status hist-status_appt";
    if (k.includes("NO_NEXT")) return "hist-status hist-status_nonext";
    if (k.includes("OFF_CADENCE")) return "hist-status hist-status_offcadence";
    if (k.includes("AWV")) return "hist-status hist-status_awv";
    if (k.includes("INACTIVE")) return "hist-status hist-status_inactive";
    if (k.includes("UNENGAGED")) return "hist-status hist-status_unengaged";
    return "hist-status hist-status_default";
  }
  get careItemGroups() {
    return this.activityGroups;
  }

  get hasCareItemGroups() {
    return this.filteredHistoryEvents.length > 0;
  }
  get timelineToggleLabel() {
    return this.timelineExpanded
      ? "Hide care item history"
      : "Show care item history";
  }
  get timelineSectionClass() {
    return (
      "oi-section oi-section_timeline" +
      (this.timelineExpanded ? "" : " oi-section_timeline_collapsed")
    );
  }

  parentKey(need) {
    const rid = (need?.ruleId || "").toUpperCase();
    const nt = (need?.needType || "").toUpperCase();
    if (rid.includes("AWV") || nt.includes("AWV")) return "AWV";
    if (rid === "OFF_CADENCE" || (nt === "OFF_CADENCE" && !rid.includes("UNENGAGED")))
      return "OFF_CADENCE";
    if (rid.startsWith("NO_NEXT") || nt.includes("NO_NEXT")) return "NO_NEXT";
    if (rid.includes("INACTIVE") || nt.includes("INACTIVE")) return "INACTIVE";
    if (rid.includes("UNENGAGED") || nt.includes("UNENGAGED")) return "UNENGAGED";
    if (rid.includes("URGENT_REFERRAL") || nt.includes("URGENT_REFERRAL"))
      return "URGENT_REFERRAL";
    if (rid === "MDDO" || nt === "MDDO" || rid.includes("MDDO")) return "MDDO";
    if (rid.includes("DISCHARGE") || nt.includes("DISCHARGE")) return "DISCHARGE_TCM";
    if (rid.includes("ADMISSION") || nt.includes("ADMISSION"))
      return "ADMISSION_TOUCHBASE";
    return nt || rid || "OTHER";
  }
  parentTitle(key, fallback) {
    if (key === "AWV") return "Annual Wellness Visit";
    if (key === "OFF_CADENCE") return "Off cadence";
    if (key === "NO_NEXT") return "No next visit";
    if (key === "UNENGAGED") return "Unengaged";
    if (key === "URGENT_REFERRAL") return "Urgent referral follow-up";
    if (key === "MDDO") return "MD/DO visit";
    if (key === "DISCHARGE_TCM") return "Discharge TCM";
    if (key === "ADMISSION_TOUCHBASE") return "Admission Touchbase";
    if (key === "ACTIVITY" || key === "OTHER") return "Outreach activity";
    return fallback || "Care item";
  }
  priorityLabel(priority) {
    const key = (priority || "").toUpperCase();
    return PRIORITY_LABELS[key] || priority || "Routine";
  }
  priorityIcon(priority) {
    const p = (priority || "").toUpperCase();
    if (p === "STAT") return "utility:warning";
    if (p === "URGENT") return "utility:priority";
    return "utility:event";
  }
  intensityClass(score, priority) {
    const p = (priority || "").toUpperCase();
    if (p === "STAT") return "intensity_high";
    if (p === "URGENT") return "intensity_mid";
    if (p === "ROUTINE") return "intensity_low";
    const n = Number(score);
    if (!Number.isFinite(n)) return "intensity_low";
    if (n >= 80) return "intensity_high";
    if (n >= 55) return "intensity_mid";
    return "intensity_low";
  }
  bootstrapSelectedNeeds() {
    // Default-select actionable needs only. Snoozed rows stay visible for
    // extend/override but are not in the outcome mutation set until toggled.
    this.selectedNeedIds = this.parentCareNeeds
      .filter((n) => (n.state || "").toUpperCase() !== "SNOOZED")
      .map((n) => n.id);
    this.acknowledgedNeedIds = [];
  }
  formatWhen(value) {
    if (!value) return "";
    try {
      const dt = new Date(value);
      if (Number.isNaN(dt.getTime())) return "";
      return dt.toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit"
      });
    } catch (e) {
      return "";
    }
  }
  formatDateOnly(value) {
    if (!value) return "";
    try {
      const dt = new Date(value);
      if (Number.isNaN(dt.getTime())) return "";
      return dt.toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric"
      });
    } catch (e) {
      return "";
    }
  }

  subscribeToChannel() {
    if (this.subscription || !this.messageContext) return;
    this._messageContext = this.messageContext;
    this.subscription = subscribe(
      this.messageContext,
      PatientOutreachState,
      (message) => this.handleMessage(message),
      { scope: APPLICATION_SCOPE }
    );
  }
  unsubscribeFromChannel() {
    if (this.subscription) {
      unsubscribe(this.subscription);
      this.subscription = null;
    }
  }
  handleMessage(message) {
    if (!message || message.recordId !== this.recordId) return;
    if (message.eventType === "REQUEST_STATE") {
      this.publishNeedState();
    } else if (message.eventType === "REFRESH") {
      this.refreshAll();
    }
  }
  publishNeedState() {
    const ctx = this._messageContext || this.messageContext;
    if (!ctx || !this.recordId) return;
    try {
      publish(ctx, PatientOutreachState, {
        eventType: "NEED_STATE",
        recordId: this.recordId,
        selectedNeedIdsJson: JSON.stringify(this.selectedNeedIds || []),
        acknowledgedNeedIdsJson: JSON.stringify(this.acknowledgedNeedIds || []),
        commentOnlyMode: this.isCommentOnlyMode
      });
    } catch (e) {
      // ignore
    }
  }
  publishRefresh() {
    const ctx = this._messageContext || this.messageContext;
    if (!ctx || !this.recordId) return;
    try {
      publish(ctx, PatientOutreachState, {
        eventType: "REFRESH",
        recordId: this.recordId
      });
    } catch (e) {
      // ignore
    }
  }
  async refreshAll() {
    await Promise.all([
      refreshApex(this.workspaceWire),
      refreshApex(this.eventsWire)
    ]);
  }

  async maybeSoftHold() {
    const episodeId = this.workspace?.episodeId;
    if (!episodeId || this.softHoldDoneFor === episodeId) return;
    // Silenced-only / empty active list: keep page readable without claiming the episode.
    if (!this.parentCareNeeds?.length) return;
    this.softHoldDoneFor = episodeId;
    try {
      await recordSoftHold({ recordId: this.recordId });
      await refreshApex(this.eventsWire);
    } catch (e) {
      // Soft hold is best-effort.
    }
  }

  handleNeedToggle(event) {
    if (event.currentTarget.disabled) return;
    const id = event.currentTarget.dataset.needId;
    const next = new Set(this.selectedNeedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    this.selectedNeedIds = [...next];
    this.publishNeedState();
  }
  handleForceAck(event) {
    const id = event.currentTarget.dataset.needId;
    const checked = event.target.checked;
    const next = new Set(this.acknowledgedNeedIds);
    if (checked) next.add(id);
    else next.delete(id);
    this.acknowledgedNeedIds = [...next];
    this.publishNeedState();
  }
  toggleTimeline() {
    this.timelineExpanded = !this.timelineExpanded;
  }

  openSilence(event) {
    this.silenceNeedId = event.currentTarget.dataset.needId;
    this.silenceExpiry = null;
    this.silenceReason = "";
    this.showSilenceForm = true;
  }
  closeSilence() {
    this.showSilenceForm = false;
  }
  handleSilenceExpiry(event) {
    this.silenceExpiry = event.detail.value;
  }
  handleSilenceReason(event) {
    this.silenceReason = event.detail.value;
  }
  async saveSilence() {
    if (!(this.silenceReason || "").trim()) {
      this.toast(
        "Reason required",
        "Explain why this patient should stop receiving these reminders.",
        "error"
      );
      return;
    }
    this.isLoading = true;
    try {
      this.workspace = await silenceNeed({
        patientId: this.workspace.patientId,
        needId: this.silenceNeedId,
        reason: this.silenceReason.trim(),
        expiry: this.silenceExpiry || null
      });
      this.showSilenceForm = false;
      this.bootstrapSelectedNeeds();
      this.publishNeedState();
      this.toast(
        "Silenced",
        "This care item will not remind the patient again.",
        "success"
      );
      await refreshApex(this.workspaceWire);
      this.enhanceSituationDescription();
      this.publishRefresh();
    } catch (e) {
      this.showError(e, "Unable to silence care item.");
    } finally {
      this.isLoading = false;
    }
  }

  async enhanceSituationDescription() {
    if (!this.recordId || !this.workspace) return;
    try {
      const enhanced = await enhanceRationale({ recordId: this.recordId });
      if (enhanced?.rationale) {
        this.workspace = {
          ...this.workspace,
          rationale: enhanced.rationale,
          rationaleSource: enhanced.rationaleSource || "PlatformAI"
        };
      }
    } catch (e) {
      // Soft-fail: keep rule-engine rationale already on workspace.
    }
  }
  async handleUnsilence(event) {
    const needId = event.currentTarget.dataset.needId;
    this.isLoading = true;
    try {
      this.workspace = await unsilenceNeed({
        patientId: this.workspace.patientId,
        needId
      });
      this.bootstrapSelectedNeeds();
      this.publishNeedState();
      this.toast("Unsilenced", "Care item is active again.", "success");
      await refreshApex(this.workspaceWire);
      this.publishRefresh();
    } catch (e) {
      this.showError(e, "Unable to unsilence care item.");
    } finally {
      this.isLoading = false;
    }
  }

  message(error, fallback) {
    return error?.body?.message || error?.message || fallback;
  }
  showError(error, fallback) {
    this.error = this.message(error, fallback);
    this.toast("Outreach", this.error, "error");
  }
  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
  datePlusDays(days) {
    const d = new Date();
    d.setDate(d.getDate() + days);
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    return `${yyyy}-${mm}-${dd}`;
  }
  get overrideMinDate() {
    return this.datePlusDays(1);
  }
  get overrideMaxDate() {
    return this.datePlusDays(365);
  }
  openOverride(event) {
    this.overrideNeedId = event.currentTarget.dataset.needId;
    this.overrideUntil = this.datePlusDays(14);
  }
  cancelOverride() {
    this.overrideNeedId = null;
    this.overrideUntil = null;
  }
  handleOverrideUntil(event) {
    this.overrideUntil = event.detail.value;
  }
  async confirmOverride() {
    if (!this.overrideNeedId || !this.overrideUntil) {
      this.toast("Date required", "Pick an override date.", "error");
      return;
    }
    const min = this.overrideMinDate;
    const max = this.overrideMaxDate;
    if (this.overrideUntil < min || this.overrideUntil > max) {
      this.toast(
        "Invalid date",
        "Override must be between tomorrow and 365 days from today.",
        "error"
      );
      return;
    }
    this.isLoading = true;
    try {
      this.workspace = await extendNeedSnooze({
        patientId: this.recordId,
        needId: this.overrideNeedId,
        snoozeUntil: this.overrideUntil
      });
      this.overrideNeedId = null;
      this.overrideUntil = null;
      this.toast("Override saved", "Snooze date updated.", "success");
      this.publishNeedState();
      this.publishRefresh();
    } catch (e) {
      this.showError(e, "Unable to override snooze.");
    } finally {
      this.isLoading = false;
    }
  }

}
