/**
 * TRODDR Contact Page JavaScript
 * Handles form validation, submission, and interactive elements
 */

document.addEventListener('DOMContentLoaded', function() {
    initContactForm();
    initFormValidation();
    initSmoothScrolling();
    initFAQInteractions();
});

/**
 * Initialize the contact form
 */
function initContactForm() {
    const form = document.getElementById('contact-form');
    if (!form) return;

    form.addEventListener('submit', handleFormSubmission);
    
    // Add real-time validation
    const inputs = form.querySelectorAll('input, select, textarea');
    inputs.forEach(input => {
        input.addEventListener('blur', () => validateField(input));
        input.addEventListener('input', () => clearFieldError(input));
    });
}

/**
 * Handle form submission
 */
async function handleFormSubmission(e) {
    e.preventDefault();
    
    const form = e.target;
    const submitBtn = form.querySelector('.contact-submit');
    
    // Validate all fields
    if (!validateForm(form)) {
        return;
    }
    
    // Show loading state
    setSubmitButtonLoading(submitBtn, true);
    
    try {
        // Simulate form submission (replace with actual endpoint)
        await submitForm(form);
        showFormMessage('success');
        resetForm(form);
    } catch (error) {
        console.error('Form submission error:', error);
        showFormMessage('error');
    } finally {
        setSubmitButtonLoading(submitBtn, false);
    }
}

/**
 * Submit form data (replace with your actual API endpoint)
 */
async function submitForm(form) {
    const formData = new FormData(form);
    const data = Object.fromEntries(formData.entries());
    
    // Simulate API call
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            // Simulate success/failure randomly for demo
            if (Math.random() > 0.1) { // 90% success rate
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 2000);
    });
    
    /* Replace the above simulation with actual API call:
    const response = await fetch('/api/contact', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
        },
        body: JSON.stringify(data)
    });
    
    if (!response.ok) {
        throw new Error('Network response was not ok');
    }
    
    return response.json();
    */
}

/**
 * Form validation functions
 */
function initFormValidation() {
    // Email validation regex
    window.emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
}

function validateForm(form) {
    const requiredFields = form.querySelectorAll('[required]');
    let isValid = true;
    
    requiredFields.forEach(field => {
        if (!validateField(field)) {
            isValid = false;
        }
    });
    
    return isValid;
}

function validateField(field) {
    const value = field.value.trim();
    const fieldType = field.type;
    const fieldName = field.name;
    
    // Clear previous errors
    clearFieldError(field);
    
    // Required field validation
    if (field.hasAttribute('required') && !value) {
        showFieldError(field, 'This field is required');
        return false;
    }
    
    // Email validation
    if (fieldType === 'email' && value && !window.emailRegex.test(value)) {
        showFieldError(field, 'Please enter a valid email address');
        return false;
    }
    
    // Name validation (no numbers or special characters)
    if ((fieldName === 'firstName' || fieldName === 'lastName') && value) {
        const nameRegex = /^[a-zA-Z\s'-]+$/;
        if (!nameRegex.test(value)) {
            showFieldError(field, 'Please enter a valid name');
            return false;
        }
    }
    
    // Message minimum length
    if (fieldName === 'message' && value && value.length < 10) {
        showFieldError(field, 'Please provide a more detailed message (minimum 10 characters)');
        return false;
    }
    
    return true;
}

function showFieldError(field, message) {
    field.classList.add('error');
    const errorElement = field.parentNode.querySelector('.error-message');
    if (errorElement) {
        errorElement.textContent = message;
    }
}

function clearFieldError(field) {
    field.classList.remove('error');
    const errorElement = field.parentNode.querySelector('.error-message');
    if (errorElement) {
        errorElement.textContent = '';
    }
}

/**
 * UI Helper Functions
 */
function setSubmitButtonLoading(button, isLoading) {
    if (isLoading) {
        button.classList.add('loading');
        button.disabled = true;
    } else {
        button.classList.remove('loading');
        button.disabled = false;
    }
}

function resetForm(form) {
    form.reset();
    
    // Clear all error states
    const errorFields = form.querySelectorAll('.error');
    errorFields.forEach(field => {
        field.classList.remove('error');
    });
    
    const errorMessages = form.querySelectorAll('.error-message');
    errorMessages.forEach(msg => {
        msg.textContent = '';
    });
}

function showFormMessage(type) {
    // Hide any existing messages
    hideFormMessages();
    
    const messageElement = document.getElementById(`form-${type}`);
    if (messageElement) {
        messageElement.style.display = 'block';
        
        // Auto-hide after 5 seconds
        setTimeout(() => {
            hideFormMessages();
        }, 5000);
        
        // Allow clicking outside to close
        setTimeout(() => {
            document.addEventListener('click', handleMessageOutsideClick);
        }, 100);
    }
}

function hideFormMessages() {
    const messages = document.querySelectorAll('.form-message');
    messages.forEach(msg => {
        msg.style.display = 'none';
    });
    document.removeEventListener('click', handleMessageOutsideClick);
}

function handleMessageOutsideClick(e) {
    const messages = document.querySelectorAll('.form-message');
    let clickedInside = false;
    
    messages.forEach(msg => {
        if (msg.contains(e.target)) {
            clickedInside = true;
        }
    });
    
    if (!clickedInside) {
        hideFormMessages();
    }
}

/**
 * Smooth scrolling for anchor links
 */
function initSmoothScrolling() {
    const anchorLinks = document.querySelectorAll('a[href^="#"]');
    
    anchorLinks.forEach(link => {
        link.addEventListener('click', function(e) {
            const href = this.getAttribute('href');
            
            // Skip if it's just "#"
            if (href === '#') return;
            
            const targetElement = document.querySelector(href);
            if (targetElement) {
                e.preventDefault();
                
                const headerOffset = 100;
                const elementPosition = targetElement.getBoundingClientRect().top;
                const offsetPosition = elementPosition + window.pageYOffset - headerOffset;
                
                window.scrollTo({
                    top: offsetPosition,
                    behavior: 'smooth'
                });
            }
        });
    });
}

/**
 * FAQ interactions
 */
function initFAQInteractions() {
    const faqItems = document.querySelectorAll('.faq-item');
    
    faqItems.forEach(item => {
        item.addEventListener('click', function() {
            // Add a subtle animation when clicked
            this.style.transform = 'scale(0.98)';
            setTimeout(() => {
                this.style.transform = '';
            }, 150);
        });
    });
}

/**
 * Email link interactions
 */
function initEmailLinks() {
    const emailLinks = document.querySelectorAll('a[href^="mailto:"]');
    
    emailLinks.forEach(link => {
        link.addEventListener('click', function() {
            // Track email clicks if analytics is available
            if (typeof gtag !== 'undefined') {
                gtag('event', 'email_click', {
                    'email_address': this.href.replace('mailto:', ''),
                    'source': 'contact_page'
                });
            }
        });
    });
}

/**
 * Keyboard navigation enhancements
 */
function initKeyboardNavigation() {
    // Allow Escape key to close form messages
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape') {
            hideFormMessages();
        }
    });
    
    // Improve form navigation with Tab key
    const form = document.getElementById('contact-form');
    if (form) {
        const formElements = form.querySelectorAll('input, select, textarea, button');
        
        formElements.forEach((element, index) => {
            element.addEventListener('keydown', function(e) {
                // Enter key should move to next field (except textarea and submit button)
                if (e.key === 'Enter' && this.tagName !== 'TEXTAREA' && this.type !== 'submit') {
                    e.preventDefault();
                    const nextElement = formElements[index + 1];
                    if (nextElement) {
                        nextElement.focus();
                    }
                }
            });
        });
    }
}

/**
 * Form analytics and tracking
 */
function trackFormInteraction(action, field = null) {
    // Google Analytics tracking (if available)
    if (typeof gtag !== 'undefined') {
        gtag('event', 'form_interaction', {
            'action': action,
            'field': field,
            'form_id': 'contact_form'
        });
    }
    
    // Custom analytics can be added here
    console.log(`Form interaction: ${action}`, field);
}

/**
 * Auto-save form data to localStorage
 */
function initFormAutoSave() {
    const form = document.getElementById('contact-form');
    if (!form) return;
    
    const STORAGE_KEY = 'troddr_contact_form_data';
    
    // Load saved data on page load
    loadFormData();
    
    // Save data on input
    const inputs = form.querySelectorAll('input, select, textarea');
    inputs.forEach(input => {
        input.addEventListener('input', saveFormData);
    });
    
    function saveFormData() {
        const formData = new FormData(form);
        const data = Object.fromEntries(formData.entries());
        
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify(data));
        } catch (e) {
            // Storage might be full or disabled
            console.warn('Could not save form data:', e);
        }
    }
    
    function loadFormData() {
        try {
            const savedData = localStorage.getItem(STORAGE_KEY);
            if (savedData) {
                const data = JSON.parse(savedData);
                
                Object.keys(data).forEach(key => {
                    const field = form.querySelector(`[name="${key}"]`);
                    if (field && data[key]) {
                        if (field.type === 'checkbox') {
                            field.checked = data[key] === 'on';
                        } else {
                            field.value = data[key];
                        }
                    }
                });
            }
        } catch (e) {
            console.warn('Could not load saved form data:', e);
        }
    }
    
    // Clear saved data when form is successfully submitted
    form.addEventListener('submit', function() {
        try {
            localStorage.removeItem(STORAGE_KEY);
        } catch (e) {
            console.warn('Could not clear saved form data:', e);
        }
    });
}

/**
 * Initialize all features
 */
document.addEventListener('DOMContentLoaded', function() {
    initContactForm();
    initFormValidation();
    initSmoothScrolling();
    initFAQInteractions();
    initEmailLinks();
    initKeyboardNavigation();
    initFormAutoSave();
    
    // Track page view
    trackFormInteraction('page_view');
});

/**
 * Export functions for external use
 */
window.ContactPageUtils = {
    validateForm,
    showFormMessage,
    hideFormMessages,
    trackFormInteraction
};