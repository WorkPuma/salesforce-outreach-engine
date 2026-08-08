import { LightningElement, api } from 'lwc';
import getPatientContextForLWC from '@salesforce/apex/PatientContextAgentService.getPatientContextForLWC';

export default class PatientContextCard extends LightningElement {
    @api recordId;

    patientData;
    error;
    isLoading = true;

    connectedCallback() {
        this.loadPatientContext();
    }

    loadPatientContext() {
        this.isLoading = true;
        this.error = undefined;

        getPatientContextForLWC({ accountId: this.recordId })
            .then(data => {
                this.patientData = data;
                this.error = undefined;
            })
            .catch(error => {
                this.error = error.body?.message || 'Error loading patient context';
                this.patientData = undefined;
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    get hasData() {
        return this.patientData && this.patientData.success;
    }

    get hasError() {
        return this.error || (this.patientData && !this.patientData.success);
    }

    get errorMessage() {
        return this.error || this.patientData?.errorMessage || 'Unable to generate insights';
    }

    get hasSummary() {
        return this.patientData?.summary && this.patientData.summary.trim().length > 0;
    }

    /**
     * Convert AI response to HTML for rich text rendering
     * Handles escaped HTML, direct HTML, and bullet point text
     */
    get summaryHtml() {
        if (!this.patientData?.summary) return '';

        let summary = this.patientData.summary.trim();

        // Unescape HTML entities if the AI returned escaped HTML
        // e.g., &lt;ul&gt; → <ul>
        if (summary.includes('&lt;') || summary.includes('&gt;')) {
            summary = this.unescapeHtml(summary);
        }

        // If already HTML (starts with < or contains HTML tags), pass through
        if (summary.startsWith('<') || /<[a-z][\s\S]*>/i.test(summary)) {
            return summary;
        }

        // Convert markdown-style bullets to HTML list
        const lines = summary.split('\n')
            .map(line => line.trim())
            .filter(line => line.length > 0);

        if (lines.length === 0) return '';

        // Check if it's a bullet list
        const isBulletList = lines.some(line => /^[-•*]\s/.test(line));

        if (isBulletList) {
            const listItems = lines
                .map(line => {
                    // Remove bullet prefix
                    let text = line.replace(/^[-•*]\s*/, '');
                    // Convert **text** to <strong>
                    text = text.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
                    // Convert *text* to <em> (for warnings/attention)
                    text = text.replace(/\*([^*]+)\*/g, '<em>$1</em>');
                    return `<li>${text}</li>`;
                })
                .join('');
            return `<ul>${listItems}</ul>`;
        }

        // For paragraph text, convert to simple paragraphs
        return lines
            .map(line => {
                let text = line;
                text = text.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
                text = text.replace(/\*([^*]+)\*/g, '<em>$1</em>');
                return `<p>${text}</p>`;
            })
            .join('');
    }

    /**
     * Unescape HTML entities returned by the AI
     */
    unescapeHtml(text) {
        const entities = {
            '&lt;': '<',
            '&gt;': '>',
            '&amp;': '&',
            '&quot;': '"',
            '&#39;': "'"
        };
        return text.replace(/&lt;|&gt;|&amp;|&quot;|&#39;/g, match => entities[match]);
    }

    handleRefresh() {
        this.loadPatientContext();
    }
}