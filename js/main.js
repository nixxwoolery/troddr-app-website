/**
 * TRODDR Main JavaScript
 * Handles homepage interactions, forms, and animations
 */

document.addEventListener('DOMContentLoaded', function() {
    initScrollAnimations();
    initWaitlistForm();
    initContactForm();
    initSmoothScrolling();
    initCardInteractions();
    initCounterAnimations();
    initFormValidation();
    trackPageAnalytics();
});

/**
 * Initialize scroll-triggered animations
 */
function initScrollAnimations() {
    const observerOptions = {
        root: null,
        rootMargin: '-10% 0px -10% 0px',
        threshold: 0.1
    };

    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('revealed');
                
                // Trigger counter animation for social proof
                if (entry.target.classList.contains('proof-item')) {
                    animateProofCounter(entry.target);
                }
            }
        });
    }, observerOptions);

    // Observe all scroll-reveal elements
    const animatableElements = document.querySelectorAll('.scroll-reveal, .proof-item');
    animatableElements.forEach(el => {
        if (!el.classList.contains('scroll-reveal')) {
            el.classList.add('scroll-reveal');
        }
        observer.observe(el);
    });
}

/**
 * Initialize waitlist form
 */
function initWaitlistForm() {
    const waitlistForm = document.getElementById('waitlist-form');
    if (!waitlistForm) return;

    waitlistForm.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        const formData = new FormData(this);
        const data = {
            name: formData.get('name'),
            email: formData.get('email'),
            source: 'homepage_waitlist'
        };

        // Show loading state
        const submitBtn = this.querySelector('button[type="submit"]');
        const originalText = submitBtn.textContent;
        submitBtn.textContent = 'Joining...';
        submitBtn.disabled = true;

        try {
            // Simulate API call (replace with actual endpoint)
            await submitWaitlistData(data);
            
            // Show success state
            submitBtn.textContent = 'Joined! ✓';
            submitBtn.style.background = 'var(--green)';
            
            // Reset form
            this.reset();
            
            // Track conversion
            trackEvent('waitlist_signup', {
                source: 'homepage',
                name: data.name
            });
            
            // Show success message
            showNotification('Welcome to the TRODDR family! We\'ll keep you updated on our launch.', 'success');
            
        } catch (error) {
            console.error('Waitlist signup error:', error);
            submitBtn.textContent = 'Try Again';
            showNotification('Something went wrong. Please try again.', 'error');
        } finally {
            // Reset button after delay
            setTimeout(() => {
                submitBtn.textContent = originalText;
                submitBtn.disabled = false;
                submitBtn.style.background = '';
            }, 3000);
        }
    });
}

/**
 * Initialize contact form
 */
function initContactForm() {
    const contactForm = document.getElementById('contact-form');
    if (!contactForm) return;

    contactForm.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        // Validate form
        if (!validateContactForm(this)) {
            return;
        }

        const formData = new FormData(this);
        const data = {
            name: formData.get('name'),
            email: formData.get('email'),
            message: formData.get('message'),
            source: 'homepage_contact'
        };

        // Show loading state
        const submitBtn = this.querySelector('.contact-submit');
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;

        try {
            // Simulate API call (replace with actual endpoint)
            await submitContactData(data);
            
            showFormMessage('contact-success');
            this.reset();
            clearFormErrors(this);
            
            // Track conversion
            trackEvent('contact_form_submit', {
                source: 'homepage',
                name: data.name
            });
            
        } catch (error) {
            console.error('Contact form error:', error);
            showFormMessage('contact-error');
        } finally {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    });

    // Add real-time validation
    const inputs = contactForm.querySelectorAll('input, textarea');
    inputs.forEach(input => {
        input.addEventListener('blur', () => validateField(input));
        input.addEventListener('input', () => clearFieldError(input));
    });
}

/**
 * Smooth scrolling for anchor links
 */
function initSmoothScrolling() {
    const anchorLinks = document.querySelectorAll('a[href^="#"]');
    
    anchorLinks.forEach(link => {
        link.addEventListener('click', function(e) {
            const href = this.getAttribute('href');
            
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
                
                // Track navigation
                trackEvent('internal_navigation', {
                    target: href,
                    source: 'homepage'
                });
            }
        });
    });
}

/**
 * Initialize card interactions
 */
function initCardInteractions() {
    // Solution cards
    const solutionCards = document.querySelectorAll('.solution-card');
    solutionCards.forEach(card => {
        card.addEventListener('click', function() {
            const cardType = this.querySelector('h3').textContent.toLowerCase();
            trackEvent('solution_card_click', {
                card_type: cardType,
                source: 'homepage'
            });
            
            // Add visual feedback
            this.style.transform = 'translateY(-8px) scale(1.02)';
            setTimeout(() => {
                this.style.transform = '';
            }, 200);
        });
    });

    // Feature cards
    const featureCards = document.querySelectorAll('.feature-card');
    featureCards.forEach(card => {
        card.addEventListener('click', function() {
            const featureType = this.querySelector('h3').textContent.toLowerCase();
            trackEvent('feature_card_click', {
                feature_type: featureType,
                source: 'homepage'
            });
        });
    });
}

/**
 * Initialize counter animations for social proof
 */
function initCounterAnimations() {
    const proofItems = document.querySelectorAll('.proof-item');
    proofItems.forEach(item => {
        item.dataset.animated = 'false';
    });
}

function animateProofCounter(proofItem) {
    const counter = proofItem.querySelector('.proof-number');
    if (!counter || proofItem.dataset.animated === 'true') return;
    
    const target = parseInt(counter.textContent.replace(/\D/g, ''));
    const suffix = counter.textContent.replace(/[\d\s]/g, '');
    const duration = 2000;
    const step = target / (duration / 16);
    
    let current = 0;
    proofItem.dataset.animated = 'true';
    
    const timer = setInterval(() => {
        current += step;
        if (current >= target) {
            current = target;
            clearInterval(timer);
        }
        
        counter.textContent = Math.floor(current) + suffix;
    }, 16);
}

/**
 * Form validation functions
 */
function initFormValidation() {
    window.emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
}

function validateContactForm(form) {
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
    
    // Name validation
    if (fieldName === 'name' && value) {
        const nameRegex = /^[a-zA-Z\s'-]+$/;
        if (!nameRegex.test(value)) {
            showFieldError(field, 'Please enter a valid name');
            return false;
        }
    }
    
    // Message minimum length
    if (fieldName === 'message' && value && value.length < 10) {
        showFieldError(field, 'Please provide a more detailed message');
        return false;
    }
    
    return true;
}

function showFieldError(field, message) {
    field.style.borderColor = '#ef4444';
    field.style.background = '#fef2f2';
    
    // Create or update error message
    let errorElement = field.parentNode.querySelector('.field-error');
    if (!errorElement) {
        errorElement = document.createElement('span');
        errorElement.className = 'field-error';
        errorElement.style.cssText = `
            color: #ef4444;
            font-size: 0.875rem;
            margin-top: 0.25rem;
            display: block;
            font-weight: 500;
        `;
        field.parentNode.appendChild(errorElement);
    }
    errorElement.textContent = message;
}

function clearFieldError(field) {
    field.style.borderColor = '';
    field.style.background = '';
    
    const errorElement = field.parentNode.querySelector('.field-error');
    if (errorElement) {
        errorElement.remove();
    }
}

function clearFormErrors(form) {
    const errorElements = form.querySelectorAll('.field-error');
    errorElements.forEach(el => el.remove());
    
    const fields = form.querySelectorAll('input, textarea');
    fields.forEach(field => {
        field.style.borderColor = '';
        field.style.background = '';
    });
}

/**
 * Form submission functions
 */
async function submitWaitlistData(data) {
    // Simulate API call (replace with actual endpoint)
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            if (Math.random() > 0.1) { // 90% success rate
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 1500);
    });
    
    /* Replace with actual API call:
    const response = await fetch('/api/waitlist', {
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

async function submitContactData(data) {
    // Simulate API call (replace with actual endpoint)
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            if (Math.random() > 0.1) { // 90% success rate
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 2000);
    });
    
    /* Replace with actual API call:
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
 * UI Helper Functions
 */
function showFormMessage(messageId) {
    hideFormMessages();
    
    const messageElement = document.getElementById(messageId);
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

function showNotification(message, type = 'info') {
    const notification = document.createElement('div');
    notification.className = `notification notification-${type}`;
    notification.innerHTML = `
        <div class="notification-content">
            <span class="notification-icon">${type === 'success' ? '✅' : type === 'error' ? '❌' : 'ℹ️'}</span>
            <span class="notification-message">${message}</span>
        </div>
    `;
    
    notification.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        background: ${type === 'success' ? '#10b981' : type === 'error' ? '#ef4444' : '#3b82f6'};
        color: white;
        padding: 1rem 1.5rem;
        border-radius: 12px;
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
        z-index: 10000;
        transform: translateX(100%);
        transition: transform 0.3s ease;
        max-width: 400px;
        font-weight: 500;
    `;
    
    document.body.appendChild(notification);
    
    // Animate in
    setTimeout(() => {
        notification.style.transform = 'translateX(0)';
    }, 10);
    
    // Auto-remove after 4 seconds
    setTimeout(() => {
        notification.style.transform = 'translateX(100%)';
        setTimeout(() => {
            if (notification.parentNode) {
                notification.parentNode.removeChild(notification);
            }
        }, 300);
    }, 4000);
}

/**
 * Analytics and tracking
 */
function trackPageAnalytics() {
    // Track page view
    trackEvent('page_view', {
        page_title: 'Homepage',
        page_location: window.location.href
    });
    
    // Track scroll depth
    let maxScroll = 0;
    let scrollMilestones = [25, 50, 75, 90];
    let trackedMilestones = new Set();
    
    window.addEventListener('scroll', () => {
        const scrollPercent = Math.round((window.scrollY / (document.body.scrollHeight - window.innerHeight)) * 100);
        
        if (scrollPercent > maxScroll) {
            maxScroll = scrollPercent;
            
            scrollMilestones.forEach(milestone => {
                if (scrollPercent >= milestone && !trackedMilestones.has(milestone)) {
                    trackedMilestones.add(milestone);
                    trackEvent('scroll_depth', {
                        percentage: milestone,
                        page: 'homepage'
                    });
                }
            });
        }
    });
    
    // Track time on page
    const startTime = Date.now();
    window.addEventListener('beforeunload', () => {
        const timeOnPage = Math.round((Date.now() - startTime) / 1000);
        trackEvent('time_on_page', {
            duration: timeOnPage,
            page: 'homepage'
        });
    });
}

function trackEvent(action, properties = {}) {
    // Google Analytics tracking
    if (typeof gtag !== 'undefined') {
        gtag('event', action, {
            event_category: 'homepage',
            ...properties
        });
    }
    
    // Custom analytics can be added here
    console.log(`Homepage event: ${action}`, properties);
}

/**
 * Card interaction handlers (for backward compatibility)
 */
window.cardClick = function(type) {
    trackEvent('solution_card_click', {
        card_type: type,
        source: 'homepage'
    });
    
    // Add visual feedback
    const card = event.target.closest('.solution-card');
    if (card) {
        card.style.transform = 'translateY(-8px) scale(1.02)';
        setTimeout(() => {
            card.style.transform = '';
        }, 200);
    }
};

window.featureClick = function(type) {
    trackEvent('feature_card_click', {
        feature_type: type,
        source: 'homepage'
    });
};

window.downloadApp = function() {
    trackEvent('download_app_click', {
        source: 'homepage'
    });
    
    // Show coming soon message
    showNotification('The TRODDR app is coming soon! Join our waitlist to be the first to know.', 'info');
};

/**
 * Keyboard navigation enhancements
 */
function initKeyboardNavigation() {
    document.addEventListener('keydown', function(e) {
        // Press Escape to close any open modals or notifications
        if (e.key === 'Escape') {
            hideFormMessages();
        }
        
        // Press '/' to focus on search (if implemented)
        if (e.key === '/' && !e.ctrlKey && !e.altKey && !e.metaKey) {
            const activeElement = document.activeElement;
            if (activeElement.tagName !== 'INPUT' && 
                activeElement.tagName !== 'TEXTAREA' && 
                !activeElement.isContentEditable) {
                e.preventDefault();
                // Focus on first form input
                const firstInput = document.querySelector('#waitlist-form input, #contact-form input');
                if (firstInput) {
                    firstInput.focus();
                }
            }
        }
    });
}

/**
 * Responsive navigation for mobile
 */
function initMobileNavigation() {
    const header = document.querySelector('.header');
    const navbar = document.querySelector('.navbar');
    
    // Create mobile menu button if needed
    if (window.innerWidth <= 768) {
        let mobileMenuBtn = navbar.querySelector('.mobile-menu-btn');
        if (!mobileMenuBtn) {
            mobileMenuBtn = document.createElement('button');
            mobileMenuBtn.className = 'mobile-menu-btn';
            mobileMenuBtn.innerHTML = '☰';
            mobileMenuBtn.setAttribute('aria-label', 'Toggle menu');
            
            const navLinks = navbar.querySelector('.nav-links');
            navbar.insertBefore(mobileMenuBtn, navLinks);
            
            mobileMenuBtn.addEventListener('click', function() {
                navLinks.classList.toggle('mobile-open');
                this.classList.toggle('active');
            });
        }
    }
    
    // Header scroll effect
    let lastScrollY = window.scrollY;
    window.addEventListener('scroll', () => {
        const currentScrollY = window.scrollY;
        
        if (currentScrollY > 100) {
            header.classList.add('scrolled');
        } else {
            header.classList.remove('scrolled');
        }
        
        // Hide header on scroll down, show on scroll up
        if (currentScrollY > lastScrollY && currentScrollY > 200) {
            header.classList.add('hidden');
        } else {
            header.classList.remove('hidden');
        }
        
        lastScrollY = currentScrollY;
    });
}

/**
 * Initialize all features
 */
document.addEventListener('DOMContentLoaded', function() {
    initScrollAnimations();
    initWaitlistForm();
    initContactForm();
    initSmoothScrolling();
    initCardInteractions();
    initCounterAnimations();
    initFormValidation();
    initKeyboardNavigation();
    initMobileNavigation();
    trackPageAnalytics();
});

/**
 * Export functions for external use
 */
window.TroddrHomepage = {
    trackEvent,
    showNotification,
    hideFormMessages,
    validateField
};

/**
 * TRODDR Main JavaScript
 * Handles homepage interactions, forms, and animations
 */

document.addEventListener('DOMContentLoaded', function() {
    initScrollAnimations();
    initWaitlistForm();
    initContactForm();
    initSmoothScrolling();
    initCardInteractions();
    initCounterAnimations();
    initFormValidation();
    trackPageAnalytics();
});

/**
 * Initialize scroll-triggered animations
 */
function initScrollAnimations() {
    const observerOptions = {
        root: null,
        rootMargin: '-10% 0px -10% 0px',
        threshold: 0.1
    };

    const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('revealed');
                
                // Trigger counter animation for social proof
                if (entry.target.classList.contains('proof-item')) {
                    animateProofCounter(entry.target);
                }
            }
        });
    }, observerOptions);

    // Observe all scroll-reveal elements
    const animatableElements = document.querySelectorAll('.scroll-reveal, .proof-item');
    animatableElements.forEach(el => {
        if (!el.classList.contains('scroll-reveal')) {
            el.classList.add('scroll-reveal');
        }
        observer.observe(el);
    });
}

/**
 * Initialize waitlist form
 */
function initWaitlistForm() {
    const waitlistForm = document.getElementById('waitlist-form');
    if (!waitlistForm) return;

    waitlistForm.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        const formData = new FormData(this);
        const data = {
            name: formData.get('name'),
            email: formData.get('email'),
            source: 'homepage_waitlist'
        };

        // Show loading state
        const submitBtn = this.querySelector('button[type="submit"]');
        const originalText = submitBtn.textContent;
        submitBtn.textContent = 'Joining...';
        submitBtn.disabled = true;

        try {
            // Simulate API call (replace with actual endpoint)
            await submitWaitlistData(data);
            
            // Show success state
            submitBtn.textContent = 'Joined! ✓';
            submitBtn.style.background = 'var(--green)';
            
            // Reset form
            this.reset();
            
            // Track conversion
            trackEvent('waitlist_signup', {
                source: 'homepage',
                name: data.name
            });
            
            // Show success message
            showNotification('Welcome to the TRODDR family! We\'ll keep you updated on our launch.', 'success');
            
        } catch (error) {
            console.error('Waitlist signup error:', error);
            submitBtn.textContent = 'Try Again';
            showNotification('Something went wrong. Please try again.', 'error');
        } finally {
            // Reset button after delay
            setTimeout(() => {
                submitBtn.textContent = originalText;
                submitBtn.disabled = false;
                submitBtn.style.background = '';
            }, 3000);
        }
    });
}

/**
 * Initialize contact form
 */
function initContactForm() {
    const contactForm = document.getElementById('contact-form');
    if (!contactForm) return;

    contactForm.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        // Validate form
        if (!validateContactForm(this)) {
            return;
        }

        const formData = new FormData(this);
        const data = {
            name: formData.get('name'),
            email: formData.get('email'),
            message: formData.get('message'),
            source: 'homepage_contact'
        };

        // Show loading state
        const submitBtn = this.querySelector('.contact-submit');
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;

        try {
            // Simulate API call (replace with actual endpoint)
            await submitContactData(data);
            
            showFormMessage('contact-success');
            this.reset();
            clearFormErrors(this);
            
            // Track conversion
            trackEvent('contact_form_submit', {
                source: 'homepage',
                name: data.name
            });
            
        } catch (error) {
            console.error('Contact form error:', error);
            showFormMessage('contact-error');
        } finally {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    });

    // Add real-time validation
    const inputs = contactForm.querySelectorAll('input, textarea');
    inputs.forEach(input => {
        input.addEventListener('blur', () => validateField(input));
        input.addEventListener('input', () => clearFieldError(input));
    });
}

/**
 * Smooth scrolling for anchor links
 */
function initSmoothScrolling() {
    const anchorLinks = document.querySelectorAll('a[href^="#"]');
    
    anchorLinks.forEach(link => {
        link.addEventListener('click', function(e) {
            const href = this.getAttribute('href');
            
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
                
                // Track navigation
                trackEvent('internal_navigation', {
                    target: href,
                    source: 'homepage'
                });
            }
        });
    });
}

/**
 * Initialize card interactions
 */
function initCardInteractions() {
    // Solution cards
    const solutionCards = document.querySelectorAll('.solution-card');
    solutionCards.forEach(card => {
        card.addEventListener('click', function() {
            const cardType = this.querySelector('h3').textContent.toLowerCase();
            trackEvent('solution_card_click', {
                card_type: cardType,
                source: 'homepage'
            });
            
            // Add visual feedback
            this.style.transform = 'translateY(-8px) scale(1.02)';
            setTimeout(() => {
                this.style.transform = '';
            }, 200);
        });
    });

    // Feature cards
    const featureCards = document.querySelectorAll('.feature-card');
    featureCards.forEach(card => {
        card.addEventListener('click', function() {
            const featureType = this.querySelector('h3').textContent.toLowerCase();
            trackEvent('feature_card_click', {
                feature_type: featureType,
                source: 'homepage'
            });
        });
    });
}

/**
 * Initialize counter animations for social proof
 */
function initCounterAnimations() {
    const proofItems = document.querySelectorAll('.proof-item');
    proofItems.forEach(item => {
        item.dataset.animated = 'false';
    });
}

function animateProofCounter(proofItem) {
    const counter = proofItem.querySelector('.proof-number');
    if (!counter || proofItem.dataset.animated === 'true') return;
    
    const target = parseInt(counter.textContent.replace(/\D/g, ''));
    const suffix = counter.textContent.replace(/[\d\s]/g, '');
    const duration = 2000;
    const step = target / (duration / 16);
    
    let current = 0;
    proofItem.dataset.animated = 'true';
    
    const timer = setInterval(() => {
        current += step;
        if (current >= target) {
            current = target;
            clearInterval(timer);
        }
        
        counter.textContent = Math.floor(current) + suffix;
    }, 16);
}

/**
 * Form validation functions
 */
function initFormValidation() {
    window.emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
}

function validateContactForm(form) {
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
    
    // Name validation
    if (fieldName === 'name' && value) {
        const nameRegex = /^[a-zA-Z\s'-]+$/;
        if (!nameRegex.test(value)) {
            showFieldError(field, 'Please enter a valid name');
            return false;
        }
    }
    
    // Message minimum length
    if (fieldName === 'message' && value && value.length < 10) {
        showFieldError(field, 'Please provide a more detailed message');
        return false;
    }
    
    return true;
}

function showFieldError(field, message) {
    field.style.borderColor = '#ef4444';
    field.style.background = '#fef2f2';
    
    // Create or update error message
    let errorElement = field.parentNode.querySelector('.field-error');
    if (!errorElement) {
        errorElement = document.createElement('span');
        errorElement.className = 'field-error';
        errorElement.style.cssText = `
            color: #ef4444;
            font-size: 0.875rem;
            margin-top: 0.25rem;
            display: block;
            font-weight: 500;
        `;
        field.parentNode.appendChild(errorElement);
    }
    errorElement.textContent = message;
}

function clearFieldError(field) {
    field.style.borderColor = '';
    field.style.background = '';
    
    const errorElement = field.parentNode.querySelector('.field-error');
    if (errorElement) {
        errorElement.remove();
    }
}

function clearFormErrors(form) {
    const errorElements = form.querySelectorAll('.field-error');
    errorElements.forEach(el => el.remove());
    
    const fields = form.querySelectorAll('input, textarea');
    fields.forEach(field => {
        field.style.borderColor = '';
        field.style.background = '';
    });
}

/**
 * Form submission functions
 */
async function submitWaitlistData(data) {
    // Simulate API call (replace with actual endpoint)
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            if (Math.random() > 0.1) { // 90% success rate
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 1500);
    });
    
    /* Replace with actual API call:
    const response = await fetch('/api/waitlist', {
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

async function submitContactData(data) {
    // Simulate API call (replace with actual endpoint)
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            if (Math.random() > 0.1) { // 90% success rate
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 2000);
    });
    
    /* Replace with actual API call:
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
 * UI Helper Functions
 */
function showFormMessage(messageId) {
    hideFormMessages();
    
    const messageElement = document.getElementById(messageId);
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

function showNotification(message, type = 'info') {
    const notification = document.createElement('div');
    notification.className = `notification notification-${type}`;
    notification.innerHTML = `
        <div class="notification-content">
            <span class="notification-icon">${type === 'success' ? '✅' : type === 'error' ? '❌' : 'ℹ️'}</span>
            <span class="notification-message">${message}</span>
        </div>
    `;
    
    notification.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        background: ${type === 'success' ? '#10b981' : type === 'error' ? '#ef4444' : '#3b82f6'};
        color: white;
        padding: 1rem 1.5rem;
        border-radius: 12px;
        box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
        z-index: 10000;
        transform: translateX(100%);
        transition: transform 0.3s ease;
        max-width: 400px;
        font-weight: 500;
    `;
    
    document.body.appendChild(notification);
    
    // Animate in
    setTimeout(() => {
        notification.style.transform = 'translateX(0)';
    }, 10);
    
    // Auto-remove after 4 seconds
    setTimeout(() => {
        notification.style.transform = 'translateX(100%)';
        setTimeout(() => {
            if (notification.parentNode) {
                notification.parentNode.removeChild(notification);
            }
        }, 300);
    }, 4000);
}

/**
 * Analytics and tracking
 */
function trackPageAnalytics() {
    // Track page view
    trackEvent('page_view', {
        page_title: 'Homepage',
        page_location: window.location.href
    });
    
    // Track scroll depth
    let maxScroll = 0;
    let scrollMilestones = [25, 50, 75, 90];
    let trackedMilestones = new Set();
    
    window.addEventListener('scroll', () => {
        const scrollPercent = Math.round((window.scrollY / (document.body.scrollHeight - window.innerHeight)) * 100);
        
        if (scrollPercent > maxScroll) {
            maxScroll = scrollPercent;
            
            scrollMilestones.forEach(milestone => {
                if (scrollPercent >= milestone && !trackedMilestones.has(milestone)) {
                    trackedMilestones.add(milestone);
                    trackEvent('scroll_depth', {
                        percentage: milestone,
                        page: 'homepage'
                    });
                }
            });
        }
    });
    
    // Track time on page
    const startTime = Date.now();
    window.addEventListener('beforeunload', () => {
        const timeOnPage = Math.round((Date.now() - startTime) / 1000);
        trackEvent('time_on_page', {
            duration: timeOnPage,
            page: 'homepage'
        });
    });
}

function trackEvent(action, properties = {}) {
    // Google Analytics tracking
    if (typeof gtag !== 'undefined') {
        gtag('event', action, {
            event_category: 'homepage',
            ...properties
        });
    }
    
    // Custom analytics can be added here
    console.log(`Homepage event: ${action}`, properties);
}

/**
 * App store click tracking
 */
window.trackAppStoreClick = function(platform) {
    trackEvent('app_store_click', {
        platform: platform,
        source: 'homepage'
    });
    
    // Show coming soon message since app isn't released yet
    // showNotification(`The TRODDR app is coming to ${platform === 'ios' ? 'iOS' : 'Android'} in early 2025! Join our waitlist to be notified.`, 'info');
    
    // Prevent actual navigation for now
    return false;
};

/**
 * Card interaction handlers (for backward compatibility)
 */
window.cardClick = function(type) {
    trackEvent('solution_card_click', {
        card_type: type,
        source: 'homepage'
    });
    
    // Add visual feedback
    const card = event.target.closest('.solution-card');
    if (card) {
        card.style.transform = 'translateY(-8px) scale(1.02)';
        setTimeout(() => {
            card.style.transform = '';
        }, 200);
    }
};

window.featureClick = function(type) {
    trackEvent('feature_card_click', {
        feature_type: type,
        source: 'homepage'
    });
};

window.downloadApp = function() {
    trackEvent('download_app_click', {
        source: 'homepage'
    });
    
    // Show coming soon message
    showNotification('The TRODDR app is coming soon! Join our waitlist to be the first to know.', 'info');
};

/**
 * Keyboard navigation enhancements
 */
function initKeyboardNavigation() {
    document.addEventListener('keydown', function(e) {
        // Press Escape to close any open modals or notifications
        if (e.key === 'Escape') {
            hideFormMessages();
        }
        
        // Press '/' to focus on search (if implemented)
        if (e.key === '/' && !e.ctrlKey && !e.altKey && !e.metaKey) {
            const activeElement = document.activeElement;
            if (activeElement.tagName !== 'INPUT' && 
                activeElement.tagName !== 'TEXTAREA' && 
                !activeElement.isContentEditable) {
                e.preventDefault();
                // Focus on first form input
                const firstInput = document.querySelector('#waitlist-form input, #contact-form input');
                if (firstInput) {
                    firstInput.focus();
                }
            }
        }
    });
}

// Mobile Navigation and Responsive Features
document.addEventListener('DOMContentLoaded', function() {
    initMobileNavigation();
    initResponsiveFeatures();
    initTouchGestures();
    initViewportOptimization();
    initWaitlistForm();
    initContactForm();
    initSmoothScrolling();
});

function initMobileNavigation() {
    const navbar = document.querySelector('.navbar');
    const navLinks = document.querySelector('.nav-links');
    const mobileMenuBtn = document.querySelector('.mobile-menu-btn');
    
    if (!navbar || !navLinks || !mobileMenuBtn) return;
    
    // Toggle menu functionality
    mobileMenuBtn.addEventListener('click', function() {
        const isOpen = navLinks.classList.contains('mobile-open');
        
        if (isOpen) {
            closeMobileMenu();
        } else {
            openMobileMenu();
        }
    });
    
    // Close menu when clicking nav links
    const navItems = navLinks.querySelectorAll('.nav-item, .nav-cta');
    navItems.forEach(item => {
        item.addEventListener('click', () => {
            closeMobileMenu();
        });
    });
    
    // Close menu when clicking outside
    document.addEventListener('click', function(e) {
        if (!navbar.contains(e.target) && navLinks.classList.contains('mobile-open')) {
            closeMobileMenu();
        }
    });
    
    // Close menu on escape key
    document.addEventListener('keydown', function(e) {
        if (e.key === 'Escape' && navLinks.classList.contains('mobile-open')) {
            closeMobileMenu();
        }
    });
    
    function openMobileMenu() {
        navLinks.classList.add('mobile-open');
        mobileMenuBtn.classList.add('active');
        mobileMenuBtn.innerHTML = '✕';
        mobileMenuBtn.setAttribute('aria-expanded', 'true');
        
        // Prevent body scroll when menu is open
        document.body.style.overflow = 'hidden';
        
        // Focus first nav item for accessibility
        const firstNavItem = navLinks.querySelector('.nav-item');
        if (firstNavItem) {
            setTimeout(() => firstNavItem.focus(), 100);
        }
    }
    
    function closeMobileMenu() {
        navLinks.classList.remove('mobile-open');
        mobileMenuBtn.classList.remove('active');
        mobileMenuBtn.innerHTML = '☰';
        mobileMenuBtn.setAttribute('aria-expanded', 'false');
        
        // Restore body scroll
        document.body.style.overflow = '';
    }
    
    // Close menu on window resize
    window.addEventListener('resize', function() {
        if (window.innerWidth > 768) {
            closeMobileMenu();
        }
    });
}

function initResponsiveFeatures() {
    // Header scroll behavior
    const header = document.querySelector('.header');
    let lastScrollY = window.scrollY;
    let ticking = false;
    
    function updateHeader() {
        const currentScrollY = window.scrollY;
        
        if (currentScrollY > 100) {
            header.classList.add('scrolled');
        } else {
            header.classList.remove('scrolled');
        }
        
        // Hide header on scroll down, show on scroll up (mobile only)
        if (window.innerWidth <= 768) {
            if (currentScrollY > lastScrollY && currentScrollY > 200) {
                header.classList.add('hidden');
            } else {
                header.classList.remove('hidden');
            }
        }
        
        lastScrollY = currentScrollY;
        ticking = false;
    }
    
    function requestTick() {
        if (!ticking) {
            requestAnimationFrame(updateHeader);
            ticking = true;
        }
    }
    
    window.addEventListener('scroll', requestTick);
}

function initTouchGestures() {
    // Add touch feedback for cards
    const cards = document.querySelectorAll('.solution-card, .feature-card');
    cards.forEach(card => {
        card.addEventListener('touchstart', function() {
            this.style.transform = 'scale(0.98)';
        }, { passive: true });
        
        card.addEventListener('touchend', function() {
            this.style.transform = '';
        }, { passive: true });
    });
}

function initViewportOptimization() {
    // Set CSS custom property for viewport height (for mobile browsers)
    function setVH() {
        const vh = window.innerHeight * 0.01;
        document.documentElement.style.setProperty('--vh', `${vh}px`);
    }
    
    setVH();
    window.addEventListener('resize', setVH);
    window.addEventListener('orientationchange', setVH);
    
    // Prevent zoom on input focus (iOS)
    const inputs = document.querySelectorAll('input, textarea, select');
    inputs.forEach(input => {
        input.addEventListener('focus', function() {
            if (window.innerWidth <= 768) {
                const viewport = document.querySelector('meta[name=viewport]');
                if (viewport) {
                    viewport.setAttribute('content', 
                        'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no'
                    );
                }
            }
        });
        
        input.addEventListener('blur', function() {
            if (window.innerWidth <= 768) {
                const viewport = document.querySelector('meta[name=viewport]');
                if (viewport) {
                    viewport.setAttribute('content', 
                        'width=device-width, initial-scale=1.0'
                    );
                }
            }
        });
    });
}

function initWaitlistForm() {
    const waitlistForm = document.getElementById('waitlist-form');
    if (!waitlistForm) return;

    waitlistForm.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        const formData = new FormData(this);
        const data = {
            name: formData.get('name'),
            email: formData.get('email'),
            source: 'homepage_waitlist'
        };

        // Show loading state
        const submitBtn = this.querySelector('button[type="submit"]');
        const originalText = submitBtn.textContent;
        submitBtn.textContent = 'Joining...';
        submitBtn.disabled = true;

        try {
            // Simulate API call (replace with actual endpoint)
            await submitWaitlistData(data);
            
            // Show success state
            submitBtn.textContent = 'Joined! ✓';
            submitBtn.style.background = 'var(--green)';
            
            // Reset form
            this.reset();
            
            // Show success message
            showNotification('Welcome to the TRODDR family! We\'ll keep you updated on our launch.', 'success');
            
        } catch (error) {
            console.error('Waitlist signup error:', error);
            submitBtn.textContent = 'Try Again';
            showNotification('Something went wrong. Please try again.', 'error');
        } finally {
            // Reset button after delay
            setTimeout(() => {
                submitBtn.textContent = originalText;
                submitBtn.disabled = false;
                submitBtn.style.background = '';
            }, 3000);
        }
    });
}

function initContactForm() {
    const contactForm = document.getElementById('contact-form');
    if (!contactForm) return;

    contactForm.addEventListener('submit', async function(e) {
        e.preventDefault();
        
        // Validate form
        if (!validateContactForm(this)) {
            return;
        }

        const formData = new FormData(this);
        const data = {
            name: formData.get('name'),
            email: formData.get('email'),
            message: formData.get('message'),
            source: 'homepage_contact'
        };

        // Show loading state
        const submitBtn = this.querySelector('.contact-submit');
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;

        try {
            // Simulate API call (replace with actual endpoint)
            await submitContactData(data);
            
            showFormMessage('contact-success');
            this.reset();
            
        } catch (error) {
            console.error('Contact form error:', error);
            showFormMessage('contact-error');
        } finally {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    });

    // Add real-time validation
    const inputs = contactForm.querySelectorAll('input, textarea');
    inputs.forEach(input => {
        input.addEventListener('blur', () => validateField(input));
    });
}

function initSmoothScrolling() {
    const anchorLinks = document.querySelectorAll('a[href^="#"]');
    
    anchorLinks.forEach(link => {
        link.addEventListener('click', function(e) {
            const href = this.getAttribute('href');
            
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

// Form validation functions
function validateContactForm(form) {
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
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    
    // Required field validation
    if (field.hasAttribute('required') && !value) {
        showFieldError(field, 'This field is required');
        return false;
    }
    
    // Email validation
    if (fieldType === 'email' && value && !emailRegex.test(value)) {
        showFieldError(field, 'Please enter a valid email address');
        return false;
    }
    
    // Name validation
    if (fieldName === 'name' && value) {
        const nameRegex = /^[a-zA-Z\s'-]+$/;
        if (!nameRegex.test(value)) {
            showFieldError(field, 'Please enter a valid name');
            return false;
        }
    }
    
    // Message minimum length
    if (fieldName === 'message' && value && value.length < 10) {
        showFieldError(field, 'Please provide a more detailed message');
        return false;
    }
    
    clearFieldError(field);
    return true;
}

function showFieldError(field, message) {
    field.style.borderColor = '#ef4444';
    field.style.background = '#fef2f2';
    
    let errorElement = field.parentNode.querySelector('.field-error');
    if (!errorElement) {
        errorElement = document.createElement('span');
        errorElement.className = 'field-error';
        errorElement.style.cssText = `
            color: #ef4444;
            font-size: 0.875rem;
            margin-top: 0.25rem;
            display: block;
            font-weight: 500;
        `;
        field.parentNode.appendChild(errorElement);
    }
    errorElement.textContent = message;
}

function clearFieldError(field) {
    field.style.borderColor = '';
    field.style.background = '';
    
    const errorElement = field.parentNode.querySelector('.field-error');
    if (errorElement) {
        errorElement.remove();
    }
}

// API simulation functions
async function submitWaitlistData(data) {
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            if (Math.random() > 0.1) {
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 1500);
    });
}

async function submitContactData(data) {
    return new Promise((resolve, reject) => {
        setTimeout(() => {
            if (Math.random() > 0.1) {
                resolve(data);
            } else {
                reject(new Error('Submission failed'));
            }
        }, 2000);
    });
}

function showFormMessage(messageId) {
    hideFormMessages();
    
    const messageElement = document.getElementById(messageId);
    if (messageElement) {
        messageElement.style.display = 'block';
        
        setTimeout(() => {
            hideFormMessages();
        }, 5000);
        
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

function showNotification(message, type = 'info') {
    const existingNotifications = document.querySelectorAll('.notification');
    existingNotifications.forEach(notification => notification.remove());
    
    const notification = document.createElement('div');
    notification.className = `notification notification-${type}`;
    
    const icons = {
        success: '✅',
        error: '❌',
        warning: '⚠️',
        info: 'ℹ️'
    };
    
    notification.innerHTML = `
        <div class="notification-content">
            <span class="notification-icon">${icons[type] || icons.info}</span>
            <span class="notification-message">${message}</span>
        </div>
    `;
    
    document.body.appendChild(notification);
    
    setTimeout(() => {
        notification.classList.add('show');
    }, 10);
    
    setTimeout(() => {
        notification.classList.remove('show');
        setTimeout(() => {
            if (notification.parentNode) {
                notification.parentNode.removeChild(notification);
            }
        }, 300);
    }, 4000);
    
    notification.addEventListener('click', () => {
        notification.classList.remove('show');
        setTimeout(() => {
            if (notification.parentNode) {
                notification.parentNode.removeChild(notification);
            }
        }, 300);
    });
}

// Performance monitoring
window.addEventListener('load', function() {
    if ('performance' in window) {
        const perfData = performance.getEntriesByType('navigation')[0];
        if (perfData && perfData.loadEventEnd > 0) {
            console.log('Page load time:', perfData.loadEventEnd - perfData.fetchStart, 'ms');
        }
    }
});
