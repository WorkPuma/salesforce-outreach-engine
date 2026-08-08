import { LightningElement, api, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { refreshApex } from "@salesforce/apex";
import { getObjectInfo, getPicklistValues } from "lightning/uiObjectInfoApi";
import ACCOUNT_OBJECT from "@salesforce/schema/Account";
import INACTIVE_REASONS_FIELD from "@salesforce/schema/Account.Inactive_Reasons__c";
import getPatientWorkspace from "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace";
import getRecentEvents from "@salesforce/apex/OutreachWorkbenchController.getRecentEvents";
import enhanceRationale from "@salesforce/apex/OutreachWorkbenchController.enhanceRationale";
import enhanceRecommendedAction from "@salesforce/apex/OutreachWorkbenchController.enhanceRecommendedAction";
import recordSoftHold from "@salesforce/apex/OutreachWorkbenchController.recordSoftHold";
import logOutcome from "@salesforce/apex/OutreachWorkbenchController.logOutcome";
import getCatalog from "@salesforce/apex/OutreachOutcomeCatalog.getCatalog";
import silenceNeed from "@salesforce/apex/OutreachWorkbenchController.silenceNeed";
import unsilenceNeed from "@salesforce/apex/OutreachWorkbenchController.unsilenceNeed";

const OUTCOMES = [
  "No Answer",
  "Left Message",
  "Connected",
  "Needs Call Back",
  "Unable to Reach",
  "Did not respond",
  "Appointment Scheduled",
  "Patient Refused Scheduling",
  "Results Received",
  "Escalated for Service Recovery",
  "Handoff To Marketing",
  "Inactive Patient",
  "Patient Deceased",
  "Snoozed"
];

const TERMINAL_OUTCOMES = new Set([
  "Unable to Reach",
  "Did not respond",
  "Appointment Scheduled",
  "Patient Refused Scheduling",
  "Results Received",
  "Escalated for Service Recovery",
  "Handoff To Marketing",
  "Inactive Patient",
  "Patient Deceased"
]);

const PATH_STAGES = ["STAT", "Urgent", "Routine"];

const INACTIVE_REASON_FALLBACK = [
  "18 Month Inactive",
  "Attend same PCP as family / significant other",
  "Care Coordination Concerns (prescriptions / referrals)",
  "Communication Issue",
  "Continuity of Care (patient mid-treatment)",
  "Cost Concerns",
  "Declined Membership",
  "Distance from Clinic",
  "Distance to the Clinic/ No Ride",
  "Insurance Coverage",
  "Issue with Prescription",
  "Moved",
  "Only wants MD / Unable to schedule with MD",
  "Other",
  "PCP comes to patient (home health / senior living)",
  "Prefers MD",
  "Provider Experiences",
  "Provider Leaving",
  "Returned to Previous Provider",
  "Satisfied with current PCP",
  "Service Offering",
  "Umbrella Network / Referrals",
  "Unknown/ Patient Refused to Give Reason",
  "Visit Experience"
];


export default class PatientOutreachPanel extends NavigationMixin(
  LightningElement
) {
  @api recordId;
  workspace;
  events = [];
  workspaceWire;
  eventsWire;
  error;
  isLoading = true;
  outcome = "Left Message";
  channel = "Phone";
  keepWorking = false;
  catalog = null;
  detail = "";
  snoozeUntil;
  closeRelated = true;
  rationaleSource = "RuleEngine";
  recommendedActionSource = "RuleEngine";
  rationaleEnhancing = false;
  softHoldDoneFor;
  selectedNeedIds = [];
  acknowledgedNeedIds = [];
  silenceNeedId;
  silenceExpiry;
  showSilenceForm = false;
  silenceReason = "";
  inactiveReason;
  inactiveReasonOptions = INACTIVE_REASON_FALLBACK.map((value) => ({ label: value, value }));
  confirmDeceased = false;
  accountRecordTypeId;

  @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
  wiredAccountInfo({ data }) {
    if (data) this.accountRecordTypeId = data.defaultRecordTypeId;
  }

  @wire(getPicklistValues, {
    recordTypeId: "$accountRecordTypeId",
    fieldApiName: INACTIVE_REASONS_FIELD
  })
  wiredInactiveReasons({ data }) {
    if (!data?.values?.length) return;
    this.inactiveReasonOptions = data.values.map((v) => ({
      label: v.label,
      value: v.value
    }));
  }

  @wire(getPatientWorkspace, { recordId: "$recordId" })
  wiredWorkspace(result) {
    this.workspaceWire = result;
    if (result.data !== undefined) {
      this.workspace = result.data || null;
      this.error = undefined;
      this.isLoading = false;
      this.bootstrapSelectedNeeds();
      this.maybeSoftHold();
      if (TERMINAL_OUTCOMES.has(this.outcome)) this.closeRelated = true;
    } else if (result.error) {
      this.error = this.message(
        result.error,
        "Unable to load outreach workspace."
      );
      this.isLoading = false;
    }
  }

  @wire(getRecentEvents, { recordId: "$recordId", rowLimit: 20 })
  wiredEvents(result) {
    this.eventsWire = result;
    if (result.data) {
      this.events = result.data.map((event) => ({
        ...event,
        statusClass: this.eventStatusClass(event.eventType)
      }));
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
  get activeNeeds() {
    return (this.workspace?.needs || []).filter(
      (n) =>
        n.state !== "Superseded" &&
        n.state !== "Shadow" &&
        n.state !== "Silenced"
    );
  }
  get silencedNeeds() {
    return (this.workspace?.needs || []).filter((n) => n.state === "Silenced");
  }
  get shadowNeeds() {
    return (this.workspace?.needs || []).filter((n) => n.state === "Shadow");
  }
  get hasShadowNeeds() {
    return this.shadowNeeds.length > 0;
  }
  get hasSilencedNeeds() {
    return this.silencedNeeds.length > 0;
  }
  get hasNeeds() {
    return this.activeNeeds.length > 0;
  }
  get needCount() {
    return this.activeNeeds.length;
  }
  get needTiles() {
    return this.activeNeeds.map((need) => {
      const selected = this.selectedNeedIds.includes(need.id);
      const force = need.forceAcknowledge === true;
      const acked = this.acknowledgedNeedIds.includes(need.id);
      return {
        ...need,
        title: need.displayLabel || need.needType,
        tileClass:
          "need-tile" +
          (selected ? " need-tile_selected" : "") +
          (force && !acked ? " need-tile_force" : ""),
        priorityClass: this.priorityClass(need.priority),
        intensityClass: this.intensityClass(need.points, need.priority),
        selected,
        force,
        acked
      };
    });
  }
  get pathStages() {
    const current = (this.workspace?.priority || "Routine").toUpperCase();
    return PATH_STAGES.map((stage) => ({
      label: stage,
      className:
        "urgency-path__stage " +
        this.intensityClass(null, stage) +
        (stage.toUpperCase() === current
          ? " urgency-path__stage_active"
          : "")
    }));
  }

  @wire(getCatalog)
  wiredCatalog({ data, error }) {
    if (data) {
      this.catalog = data;
    } else if (error) {
      // Fall back to hardcoded OUTCOMES / CHANNELS
      this.catalog = null;
    }
  }

  get outcomeOptions() {
    const rows = this.catalog?.callResults;
    if (rows && rows.length) {
      return rows.map((r) => ({ label: r.label, value: r.label }));
    }
    return OUTCOMES.map((value) => ({ label: value, value }));
  }
  get channelOptions() {
    const rows = this.catalog?.channels;
    if (rows && rows.length) {
      return rows.map((r) => ({ label: r.label, value: r.label }));
    }
    return [
      { label: "Phone", value: "Phone" },
      { label: "SMS", value: "SMS" },
      { label: "Email", value: "Email" },
      { label: "Portal", value: "Portal" }
    ];
  }
  get isSnoozedOutcome() {
    return this.outcome === "Snoozed";
  }
  get isCommentOnlyMode() {
    return !!this.workspace?.commentOnlyMode;
  }
  get cooldownBanner() {
    return this.workspace?.cooldownMessage || "";
  }
  get outcomeSectionLabel() {
    return this.isCommentOnlyMode ? "Comment only" : "Log outcome";
  }
  get showInactiveReason() {
    return this.outcome === "Inactive Patient";
  }
  get showDeceasedConfirm() {
    return this.outcome === "Patient Deceased";
  }
  get displayRationale() {
    const raw = this.workspace?.rationale || "";
    return raw.replace(/\s*Next step:.*$/i, "").trim();
  }
  get recommendedActionText() {
    return (
      this.workspace?.recommendedAction ||
      this.workspace?.nextAction ||
      "Review outreach"
    );
  }
  get actionDescriptionText() {
    return this.workspace?.actionDescription || "";
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
  get actionTextClass() {
    return (
      "action-text " +
      this.intensityClass(this.workspace?.points, this.workspace?.priority)
    );
  }
  
  get consentChips() {
    const w = this.workspace || {};
    const chips = [
      {
        key: 'email',
        label: w.emailOptedOut ? 'Email opted out' : 'Email OK',
        className: w.emailOptedOut ? 'consent-chip consent-chip_out' : 'consent-chip consent-chip_ok',
        title: 'Email channel hard-stop / global opt-out (read-only)'
      },
      {
        key: 'sms',
        label: w.smsOptedOut ? 'SMS opted out' : 'SMS OK',
        className: w.smsOptedOut ? 'consent-chip consent-chip_out' : 'consent-chip consent-chip_ok',
        title: 'SMS channel hard-stop / consent (read-only)'
      },
      {
        key: 'ai_outreach',
        label: w.ai_outreachOptedOut ? 'AI_Outreach opted out' : 'AI_Outreach OK',
        className: w.ai_outreachOptedOut ? 'consent-chip consent-chip_out' : 'consent-chip consent-chip_ok',
        title: 'AI_Outreach voice opt-out (read-only)'
      }
    ];
    return chips;
  }

get focusChips() {
    const chips = [];
    for (const need of this.activeNeeds) {
      chips.push({
        key: need.id || need.ruleId,
        label: need.displayLabel || need.needType,
        className: "oi-pill " + this.intensityClass(need.points, need.priority)
      });
    }
    if (this.workspace?.engagementScore != null) {
      chips.push({
        key: "engagement",
        label: "Engagement " + this.workspace.engagementScore,
        className:
          "oi-pill " + this.intensityClass(this.workspace.engagementScore, null)
      });
    }
    if (this.workspace?.pressureScore != null) {
      chips.push({
        key: "pressureScore",
        label: "Pressure " + this.workspace.pressureScore,
        className: "oi-pill"
      });
    }
    return chips;
  }
  get timelineEvents() {
    return (this.events || []).map((event) => {
      const type = (event.eventType || "").toLowerCase();
      let variant = "neutral";
      if (type.includes("connected") || type.includes("scheduled"))
        variant = "good";
      else if (type.includes("comment")) variant = "comment";
      else if (type.includes("reviewed") || type.includes("snoozed"))
        variant = "muted";
      else if (type.includes("handoff") || type.includes("silenced"))
        variant = "warn";
      else if (type.includes("attempt")) variant = "attempt";
      return {
        ...event,
        whenLabel: this.formatWhen(event.eventAt),
        itemClass: "timeline__item timeline__item_" + variant,
        nodeClass: "timeline__node timeline__node_" + variant,
        typeClass: "timeline__type timeline__type_" + variant
      };
    });
  }
  get hasTimelineEvents() {
    return this.timelineEvents.length > 0;
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
  priorityClass(priority) {
    return this.intensityClass(null, priority);
  }
  bootstrapSelectedNeeds() {
    this.selectedNeedIds = this.activeNeeds.map((n) => n.id);
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

  async maybeSoftHold() {
    const episodeId = this.workspace?.episodeId;
    if (!episodeId || this.softHoldDoneFor === episodeId) return;
    this.softHoldDoneFor = episodeId;
    try {
      await recordSoftHold({ recordId: this.recordId });
      await refreshApex(this.eventsWire);
    } catch (e) {
      // Soft hold is best-effort.
    }
  }

  handleNeedToggle(event) {
    const id = event.currentTarget.dataset.needId;
    const next = new Set(this.selectedNeedIds);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    this.selectedNeedIds = [...next];
  }
  handleForceAck(event) {
    const id = event.currentTarget.dataset.needId;
    const checked = event.target.checked;
    const next = new Set(this.acknowledgedNeedIds);
    if (checked) next.add(id);
    else next.delete(id);
    this.acknowledgedNeedIds = [...next];
  }
  handleOutcomeChange(event) {
    this.outcome = event.detail.value;
    if (this.outcome !== "Snoozed") this.snoozeUntil = null;
    if (this.outcome !== "Inactive Patient") this.inactiveReason = null;
    if (this.outcome !== "Patient Deceased") this.confirmDeceased = false;
    this.closeRelated = TERMINAL_OUTCOMES.has(this.outcome);
  }
  handleChannelChange(event) {
    this.channel = event.detail.value;
  }
  handleDetailChange(event) {
    this.detail = event.detail.value;
  }
  handleSnoozeUntil(event) {
    this.snoozeUntil = event.detail.value;
  }
  handleCloseRelated(event) {
    this.closeRelated = event.target.checked;
  }
  handleInactiveReason(event) {
    this.inactiveReason = event.detail.value;
  }
  handleConfirmDeceased(event) {
    this.confirmDeceased = event.target.checked;
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
      this.toast("Reason required", "Enter why this care item is being silenced.", "warning");
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
      this.toast(
        "Silenced",
        "This care item will not remind the patient again.",
        "success"
      );
      await refreshApex(this.workspaceWire);
    } catch (e) {
      this.showError(e, "Unable to silence need.");
    } finally {
      this.isLoading = false;
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
      this.toast("Unsilenced", "Need is active again.", "success");
      await refreshApex(this.workspaceWire);
    } catch (e) {
      this.showError(e, "Unable to unsilence need.");
    } finally {
      this.isLoading = false;
    }
  }


  handleKeepWorking(event) {
    this.keepWorking = event.target.checked;
  }

  async saveOutcome() {
    if (!this.workspace?.episodeId) return;

    const commentOnly = this.isCommentOnlyMode;
    if (commentOnly) {
      if (!(this.detail || "").trim()) {
        this.toast(
          "Comment required",
          "Add a comment — status changes are locked today.",
          "error"
        );
        return;
      }
    } else {
      if (this.isSnoozedOutcome && !this.snoozeUntil) {
        this.toast("Snooze date required", "Pick a wake-up date.", "error");
        return;
      }
      if (this.showInactiveReason && !this.inactiveReason) {
        this.toast(
          "Inactive reason required",
          "Select why the patient is inactive before saving.",
          "error"
        );
        return;
      }
      if (this.showDeceasedConfirm && !this.confirmDeceased) {
        this.toast(
          "Confirmation required",
          "Confirm the patient is deceased before saving.",
          "error"
        );
        return;
      }
      for (const need of this.activeNeeds) {
        if (
          this.selectedNeedIds.includes(need.id) &&
          need.forceAcknowledge &&
          !this.acknowledgedNeedIds.includes(need.id)
        ) {
          this.toast(
            "Confirmation required",
            `Confirm that "${need.displayLabel || need.needType}" was addressed.`,
            "error"
          );
          return;
        }
      }
    }

    this.isLoading = true;
    try {
      this.workspace = await logOutcome({
        episodeId: this.workspace.episodeId,
        outcome: this.outcome,
        channel: this.channel,
        detail: this.detail,
        snoozeUntil: this.snoozeUntil || null,
        closeRelated: commentOnly ? false : this.closeRelated,
        selectedNeedIds: commentOnly ? [] : this.selectedNeedIds,
        acknowledgedNeedIds: commentOnly ? [] : this.acknowledgedNeedIds,
        caseStatus: null,
        disposition: null,
        inactiveReason: commentOnly ? null : this.inactiveReason || null,
        commentOnly,
        keepWorking: this.keepWorking === true
      });
      this.toast(
        commentOnly ? "Comment saved" : "Outcome logged",
        commentOnly
          ? "Comment saved. Outcomes stay locked until tomorrow."
          : "Outreach outcome saved.",
        "success"
      );
      this.detail = "";
      this.inactiveReason = null;
      this.confirmDeceased = false;
      this.bootstrapSelectedNeeds();
      await Promise.all([
        refreshApex(this.workspaceWire),
        refreshApex(this.eventsWire)
      ]);
    } catch (e) {
      this.showError(
        e,
        commentOnly ? "Unable to save comment." : "Unable to log outcome."
      );
    } finally {
      this.isLoading = false;
    }
  }

  eventStatusClass(type) {
    const t = (type || "").toLowerCase();
    if (t.includes("scheduled") || t.includes("connected"))
      return "event-pill event-pill_good";
    if (t.includes("snoozed") || t.includes("reviewed") || t.includes("comment"))
      return "event-pill event-pill_muted";
    if (t.includes("silenced") || t.includes("handoff"))
      return "event-pill event-pill_warn";
    return "event-pill";
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
}