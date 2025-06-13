import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { CloseActionScreenEvent } from 'lightning/actions';
import processRecordImport from '@salesforce/apex/CSVRecordImportController.processRecordImport';
import getAvailableFields from '@salesforce/apex/CSVRecordImportController.getAvailableFields';
import getDefaultFieldMapping from '@salesforce/apex/CSVRecordImportController.getDefaultFieldMapping';
import getTargetFieldMappings from '@salesforce/apex/CSVRecordImportController.getTargetFieldMappings';

export default class CSVRecordImport extends NavigationMixin(LightningElement) {
    @api recordId;
    @api parentFieldReference;
    @api maxRecords;
    @api objectToCreate;
    @api mappingMetadataObject;
    showPreviousButton = false;
    currentStep = 'upload';
    uploadedFileName = '';
    fileContent = '';
    isProcessing = false;
    importResults = null;
    availableFields = [];
    csvHeaders = [];
    fieldMapping = {};
    fieldMappingItems = [];
    draftValues = [];
    defaultFieldMapping = {}; // Store the default mapping from Apex
    
    // Constants
    MAX_FILE_SIZE = 10485760; // 10MB

    mappingColumns = [
        { label: 'Field Label', fieldName: 'label', type: 'text' },
        { label: 'API Name', fieldName: 'apiName', type: 'text' },
        { label: 'CSV Column', fieldName: 'mappedTo', type: 'text', editable: true },
        // { 
        //     label: 'CSV Column',
        //     fieldName: 'mappedTo',
        //     type: 'combobox',
        //     typeAttributes: {
        //         placeholder: 'Choose CSV Column',
        //         options: { fieldName: 'csvOptions' },
        //         value: { fieldName: 'mappedTo' },
        //         context: { fieldName: 'apiName' },
        //         variant: 'label-hidden',
        //         dropdownAlignment: 'auto'
        //     },
        //     editable: true,
        //     actions: [
        //         { label: 'Clear Selection', name: 'clear_selection' }
        //     ]
        // }
    ];

    connectedCallback() {
        // Load available fields
        this.loadAvailableFields();
        console.log('Parent Field Reference:', this.parentFieldReference);
        console.log('Max Records:', this.maxRecords);
    }

    loadAvailableFields() {
        console.log('Loading available fields...');
        console.log('Object to create:', this.objectToCreate);
        console.log('Mapping metadata object:', this.mappingMetadataObject);
        getAvailableFields({ 
            objectToCreate: this.objectToCreate,
            mappingMetadataObject: this.mappingMetadataObject
        })
            .then(result => {
                console.log('Available fields loaded:', result);
                this.availableFields = result;
                // Load the default field mapping and store it
                return getDefaultFieldMapping({
                    mappingMetadataObject: this.mappingMetadataObject
                });
            })
            .then(result => {
                console.log('Default field mapping loaded:', result);
                this.defaultFieldMapping = result; // Store default mapping
                // Initialize field mapping as empty initially
                this.fieldMapping = {};
                this.updateFieldMappingItems();
            })
            .catch(error => {
                console.error('Error loading field configuration:', error);
                this.showToast('Error', 'Error loading field configuration: ' + this.getErrorMessage(error), 'error');
            });
    }

    updateFieldMappingItems() {
        console.log('Updating field mapping items...');
        console.log('Available fields:', this.availableFields);
        console.log('CSV headers:', this.csvHeaders);
        console.log('Current field mapping:', this.fieldMapping);
        
        if (!this.availableFields || this.availableFields.length === 0) {
            console.log('No available fields found');
            return;
        }
        
        this.fieldMappingItems = this.availableFields.map(field => {
            // Only use existing mapping if the mapped column exists in the CSV headers
            let mappedTo = '';
            
            if (this.fieldMapping[field.apiName]) {
                const currentMapping = this.fieldMapping[field.apiName];
                // Check if the currently mapped column exists in CSV headers
                if (this.csvHeaders && this.csvHeaders.includes(currentMapping)) {
                    mappedTo = currentMapping;
                } else {
                    // If the mapped column doesn't exist in CSV, clear it
                    console.log(`Clearing invalid mapping for ${field.apiName}: ${currentMapping} not found in CSV headers`);
                    mappedTo = '';
                }
            }
            
            // Create options with all CSV headers plus N/A option
            const options = [
                { label: '-- N/A --', value: 'N/A' }
            ];
            
            // Add CSV headers if they exist
            if (this.csvHeaders && this.csvHeaders.length > 0) {
                this.csvHeaders.forEach(header => {
                    if (header && header.trim()) {
                        options.push({ label: header, value: header });
                    }
                });
            }
            
            const mappingItem = {
                label: field.label,
                apiName: field.apiName,
                mappedTo: mappedTo,
                csvOptions: options
            };
            
            console.log('Created mapping item:', mappingItem);
            return mappingItem;
        });
        
        console.log('Final field mapping items:', this.fieldMappingItems);
    }

    get isUploadStep() {
        return this.currentStep === 'upload';
    }

    get isMappingStep() {
        return this.currentStep === 'mapping';
    }

    get isProcessingStep() {
        return this.currentStep === 'processing';
    }
    get isSummaryStep() {
        return this.currentStep === 'summary';
    }

    get uploadedFiles() {
        return this.uploadedFileName ? [this.uploadedFileName] : [];
    }

    get isUploadNextDisabled() {
        return !this.fileContent;
    }

    get isMappingNextDisabled() {
        // Disable if we don't have any field mapping items loaded
        return !this.hasFieldMappingItems;
    }

    get statusClass() {
        return this.importResults && this.importResults.success ? 'slds-text-color_success' : 'slds-text-color_error';
    }

    get statusText() {
        return this.importResults && this.importResults.success ? 'Success' : 'Failed';
    }
    
    get hasFieldMappingItems() {
        return this.fieldMappingItems && this.fieldMappingItems.length > 0;
    }

    get debugInfo() {
        return {
            availableFields: this.availableFields ? this.availableFields.length : 0,
            csvHeaders: this.csvHeaders ? this.csvHeaders.length : 0,
            fieldMappingItems: this.fieldMappingItems ? this.fieldMappingItems.length : 0,
            fieldMapping: this.fieldMapping ? Object.keys(this.fieldMapping).length : 0
        };
    }

    handleFileUpload(event) {
        const file = event.target.files[0];
        
        if (file.size > this.MAX_FILE_SIZE) {
            this.showToast('Error', 'File size exceeds maximum limit of 10MB', 'error');
            return;
        }

        if (file.type !== 'text/csv' && !file.name.endsWith('.csv')) {
            this.showToast('Error', 'Please upload a CSV file', 'error');
            return;
        }

        this.uploadedFileName = file.name;
        
        const reader = new FileReader();
        reader.onload = (e) => {
            this.fileContent = e.target.result;
            
            // Parse the CSV headers
            const lines = this.fileContent
                .split('\n')
                .filter(line => line.trim().length > 0);

            if (lines.length - 1 > this.maxRecords && this.maxRecords != null) { //subtract 1 for header row
                this.showToast('Error', `CSV file exceeds maximum record limit of ${this.maxRecords}`, 'error');
                this.fileContent = ''; //clear file content
                this.uploadedFileName = ''; //clear uploaded file name
                return;
            }
            if (lines.length > 0) {
                this.csvHeaders = lines[0].split(',').map(h => h.trim().replace(/"/g, ''));
                console.log('Parsed CSV headers:', this.csvHeaders);
                
                // Clear existing field mapping since we have new CSV headers
                this.fieldMapping = {};
                
                // Force update of field mapping items when CSV headers are available
                this.updateFieldMappingItems();
                
                // Show success message
                this.showToast('Success', `CSV file loaded successfully. Found ${this.csvHeaders.length} columns.`, 'success');
            }
        };
        reader.readAsText(file);
    }

    handleNext() {
        if (this.currentStep === 'upload') {
            this.showPreviousButton = true;
            console.log('Moving to mapping step...');
            console.log('Available fields count:', this.availableFields ? this.availableFields.length : 0);
            console.log('CSV headers count:', this.csvHeaders ? this.csvHeaders.length : 0);
            console.log('Field mapping items count:', this.fieldMappingItems ? this.fieldMappingItems.length : 0);
            this.handleAutoMatch();
            // Ensure field mapping items are updated before showing mapping step
            if (this.availableFields && this.availableFields.length > 0) {
                this.updateFieldMappingItems();
            } else {
                // Try to reload available fields if they're missing
                this.loadAvailableFields();
            }
            
            this.currentStep = 'mapping';
        } else if (this.currentStep === 'mapping') {
            // Import the LAT
            this.currentStep = 'processing';
            this.processRecordImport();
        }
    }

    handlePrevious() {
        if (this.currentStep === 'mapping') {
            this.currentStep = 'upload';
            this.showPreviousButton = false; // Hide 'Previous' button on upload step
        } else if (this.currentStep === 'processing') {
            this.currentStep = 'mapping';
        } else if (this.currentStep === 'summary') {
            this.currentStep = 'mapping';
        }
    }

    handleFinish() {
        this.currentStep = 'upload';
        this.uploadedFileName = ''; //clear uploaded file name
        this.fileContent = ''; //clear file content
        //this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleMappingAction(event) {
        const action = event.detail.action;
        const row = event.detail.row;
        
        if (action.name === 'clear_selection') {
            // Clear the mapping for this field
            const updatedMapping = { ...this.fieldMapping };
            delete updatedMapping[row.apiName];
            this.fieldMapping = updatedMapping;
            this.updateFieldMappingItems();
            
            // Show confirmation
            this.showToast('Success', `Mapping cleared for ${row.label}`, 'success');
            
            console.log(`Cleared mapping for ${row.apiName}`);
            console.log('Updated field mapping:', this.fieldMapping);
        }
    }
    
    // Fixed cell change handler for datatable
    handleCellChange(event) {
        console.log('Cell change event received:', event.detail);        
        // Get the draft values from the event
        const draftValues = event.detail.draftValues;
        
        if (!draftValues || draftValues.length === 0) {
            console.log('No draft values found in cell change event');
            return;
        }
        
        // Process each draft value
        draftValues.forEach(draftValue => {
            const fieldApiName = draftValue.apiName; // This should be the row identifier
            const newMappedValue = draftValue.mappedTo;
            
            console.log(`Processing draft value: ${fieldApiName} -> ${newMappedValue}`);
            
            // Update the field mapping
            const updatedMapping = { ...this.fieldMapping };
            
            if (newMappedValue === 'N/A' || newMappedValue === null || newMappedValue === '') {
                // If N/A is selected or the value is empty, remove from mapping entirely
                delete updatedMapping[fieldApiName];
                console.log(`Removed mapping for ${fieldApiName}`);
            } else {
                // Validate that the selected CSV column actually exists
                if (this.csvHeaders && this.csvHeaders.includes(newMappedValue)) {
                    updatedMapping[fieldApiName] = newMappedValue;
                    console.log(`Set mapping for ${fieldApiName} to ${newMappedValue}`);
                } else {
                    console.log(`Warning: CSV column ${newMappedValue} not found in headers, skipping mapping`);
                    this.showToast('Warning', `CSV column "${newMappedValue}" not found in uploaded file`, 'warning');
                    return;
                }
            }
            
            this.fieldMapping = updatedMapping;
        });
        
        // Update the field mapping items to reflect the changes
        this.updateFieldMappingItems();
        
        // Clear draft values after processing
        this.draftValues = [];
        
        // Show success message
        this.showToast('Success', 'Field mapping updated', 'success');
        
        console.log('Final field mapping after cell change:', this.fieldMapping);
    }

    handleAutoMatch() {
        if (!this.csvHeaders || this.csvHeaders.length === 0) {
            this.showToast('Warning', 'Please upload a CSV file first before auto-matching', 'warning');
            return;
        }

        // Enhanced auto-match based on similarity between field names and CSV headers
        const newMapping = {};
        const matchLog = [];

        const directMappings = {};
        getTargetFieldMappings({
            mappingMetadataObject: this.mappingMetadataObject
        })
            .then(result => {
                this.directMappings = result;
                console.log('MAPPING LOADED:', this.directMappings);
            })
            .catch(error => {
                console.error('Error loading mappings:', error);
            });
        
        // Also generate normalized versions of all direct mappings
        const normalizedDirectMappings = {};
        for (const [fieldName, mappings] of Object.entries(directMappings)) {
            normalizedDirectMappings[fieldName] = mappings.map(mapping => 
                mapping.trim().toLowerCase().replace(/[\s-]/g, '_').replace(/[^a-zA-Z0-9_]/g, '')
            );
        }
        
        // First try direct mappings using our comprehensive mapping table
        this.availableFields.forEach(field => {
            if (directMappings[field.apiName]) { 
                // Try exact matches from our mapping table
                const possibleMatches = directMappings[field.apiName];
                const normalizedPossibleMatches = normalizedDirectMappings[field.apiName];
                
                // Look for exact match in original headers - only check headers that actually exist
                let foundMatch = null;
                for (const match of possibleMatches) {
                    const headerIndex = this.csvHeaders.findIndex(h => 
                        h.trim().toLowerCase() === match.toLowerCase()
                    );
                    if (headerIndex >= 0) {
                        foundMatch = this.csvHeaders[headerIndex];
                        break;
                    }
                }
                
                // If not found, try with normalized headers
                if (!foundMatch) {
                    for (const normalizedMatch of normalizedPossibleMatches) {
                        // Try to find it in the normalized versions of the headers
                        const normalizedHeaderIndex = this.csvHeaders.findIndex(h => {
                            const normalized = h.trim().toLowerCase().replace(/[\s-]/g, '_').replace(/[^a-zA-Z0-9_]/g, '');
                            return normalized === normalizedMatch;
                        });
                        if (normalizedHeaderIndex >= 0) {
                            foundMatch = this.csvHeaders[normalizedHeaderIndex];
                            break;
                        }
                    }
                }
                
                if (foundMatch) {
                    // Double-check that the found match actually exists in CSV headers
                    if (this.csvHeaders.includes(foundMatch)) {
                        newMapping[field.apiName] = foundMatch;
                        matchLog.push(`Direct match found: ${field.apiName} -> "${foundMatch}"`);
                    }
                    return; // Skip the rest of the processing for this field
                }
            }
            
            // Try to match with similar text for fields not in our direct mapping
            let bestMatch = null;
            let bestScore = 0;
            
            this.csvHeaders.forEach(header => {
                // Skip if we already matched this header to another field
                if (Object.values(newMapping).includes(header)) {
                    return;
                }
                
                // Calculate similarity score
                let score = 0;
                
                // 1. Check if header contains the field name or vice versa
                const normalizedHeader = header.toLowerCase();
                const normalizedField = field.apiName.toLowerCase().replace('__c', '');
                
                if (normalizedHeader === normalizedField) {
                    score = 1.0; // Perfect match
                } else if (normalizedHeader.includes(normalizedField) || normalizedField.includes(normalizedHeader)) {
                    score = 0.8; // Substring match
                } else {
                    // 2. Check for word-level similarity
                    const headerWords = normalizedHeader.split(/[\s_-]+/);
                    const fieldWords = normalizedField.split(/[\s_-]+/);
                    
                    const commonWords = headerWords.filter(word => 
                        fieldWords.some(fieldWord => 
                            word === fieldWord || word.includes(fieldWord) || fieldWord.includes(word)
                        )
                    ).length;
                    
                    if (commonWords > 0) {
                        score = 0.5 * (commonWords / Math.max(headerWords.length, fieldWords.length));
                    }
                }
                
                if (score > bestScore) {
                    bestScore = score;
                    bestMatch = header;
                }
            });
            
            // Only use match if it's good enough and the header actually exists
            if (bestScore >= 0.5 && bestMatch && this.csvHeaders.includes(bestMatch)) {
                newMapping[field.apiName] = bestMatch;
                matchLog.push(`Similarity match: ${field.apiName} -> "${bestMatch}" (score: ${bestScore.toFixed(2)})`);
            }
        });
        
        // Log match details to console for debugging
        console.log('Auto-match results:', matchLog);
        
        this.fieldMapping = newMapping;
        this.updateFieldMappingItems();
        
        const matchCount = Object.keys(newMapping).length;
        const totalFields = this.availableFields.length;
        
        this.showToast('Success', `Auto-match completed: ${matchCount} of ${totalFields} fields matched with existing CSV columns.`, 'success');
    }

    async processRecordImport() {
        this.isProcessing = true;
        console.log('currentStep: ' + this.currentStep);

        try {
            // Validate that we have field mappings
            const mappingsCount = Object.keys(this.fieldMapping).length;
            if (mappingsCount === 0) {
                this.showToast('Warning', 'No field mappings configured. Please map at least one field before importing.', 'warning');
                this.isProcessing = false;
                return;
            }

            // Parse CSV to get rows
            const rows = this.parseCSV(this.fileContent);
            
            // Clean up the mapping - remove any N/A values and ensure only valid mappings are sent
            const cleanedMapping = {};
            Object.keys(this.fieldMapping).forEach(fieldName => {
                const csvColumn = this.fieldMapping[fieldName];
                // Additional validation to ensure the CSV column exists
                if (csvColumn && csvColumn !== 'N/A' && csvColumn.trim() !== '' && 
                    this.csvHeaders && this.csvHeaders.includes(csvColumn)) {
                    cleanedMapping[fieldName] = csvColumn;
                } else if (csvColumn && !this.csvHeaders.includes(csvColumn)) {
                    console.log(`Skipping invalid mapping: ${fieldName} -> ${csvColumn} (column not found in CSV)`);
                }
            });
            
            // Enhanced debugging for field mappings
            console.log('Original field mapping:', JSON.stringify(this.fieldMapping));
            console.log('Cleaned field mapping being sent to backend:', JSON.stringify(cleanedMapping));
            console.log('CSV Headers:', JSON.stringify(this.csvHeaders));
            console.log('First row of data:', JSON.stringify(rows[0]));
            
            // Validate that we still have mappings after cleaning
            if (Object.keys(cleanedMapping).length === 0) {
                this.showToast('Error', 'No valid field mappings found. Please ensure your CSV contains the expected columns.', 'error');
                this.isProcessing = false;
                return;
            }
            
            // Call Apex to process the import
            const result = await processRecordImport({
                parentId: this.recordId,
                parentField: this.parentFieldReference,
                objectToCreate: this.objectToCreate,
                mappingMetadataObject: this.mappingMetadataObject,
                csvContent: this.fileContent,
                fileName: this.uploadedFileName,
                csvRows: rows,
                fieldMapping: cleanedMapping // Send the cleaned mapping
            });

            console.log('currentStep: ' + this.currentStep);
            this.importResults = result;
            
            if (result.success) {
                this.showToast('Success', 'Classes imported successfully', 'success');
            } else {
                this.showToast('Error', 'Some errors occurred during import', 'error');
            }
        } catch (error) {
            console.error('Error importing Classes:', error);
            this.showToast('Error', 'An error occurred while importing the Classes: ' + this.getErrorMessage(error), 'error');
            this.currentStep = 'mapping';
        } finally {
            this.isProcessing = false;
            this.currentStep = 'summary'; // Go to summary step
            this.showPreviousButton = false;
            console.log('currentStep: ' + this.currentStep);

        }
    }
    
    parseCSV(csvContent) {
        // Improved CSV parser - handles quoted values and commas within fields
        const lines = csvContent.split('\n');
        const headers = this.parseCSVLine(lines[0]);
        
        console.log('Original headers:', headers);
        
        const rows = [];

        for (let i = 1; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line) {
                const values = this.parseCSVLine(line);
                const row = {};
                // Use original headers
                headers.forEach((header, index) => {
                    const value = index < values.length ? values[index] : '';
                    const trimmedValue = value.trim();
                    row[header] = trimmedValue;
                });
                rows.push(row);
            }
        }

        return rows;
    }
    
    parseCSVLine(line) {
        // Handle CSV line parsing with support for quoted values
        const result = [];
        let current = '';
        let inQuotes = false;
        
        for (let i = 0; i < line.length; i++) {
            const char = line[i];
            
            if (char === '"') {
                // Toggle inQuotes status
                inQuotes = !inQuotes;
            } else if (char === ',' && !inQuotes) {
                // End of field
                result.push(current);
                current = '';
            } else {
                current += char;
            }
        }
        
        // Add the last field
        result.push(current);
        
        // Clean up quotes from fields
        return result.map(field => {
            // Remove surrounding quotes
            if (field.startsWith('"') && field.endsWith('"')) {
                return field.substring(1, field.length - 1);
            }
            return field;
        });
    }

    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }
    
    // Helper method to get error message from error object
    getErrorMessage(error) {
        if (typeof error === 'string') {
            return error;
        }
        if (error.body && typeof error.body.message === 'string') {
            return error.body.message;
        }
        if (error.message) {
            return error.message;
        }
        return JSON.stringify(error);
    }
};