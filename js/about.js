/**
 * TRODDR About Page JavaScript
 * Handles animations, scroll effects, and interactive elements
 */

document.addEventListener('DOMContentLoaded', function() {
    initScrollAnimations();
    initCounterAnimations();
    initProgressiveDisclosure();
    initSmoothScrolling();
    initParallaxEffects();
    trackPageViews();
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
                
                // Trigger counter animation if it's a stat element
                if (entry.target.classList.contains('impact-stat') || 
                    entry.target.classList.contains('stat')) {
                    animateCounter(entry.target);
                }
            }
        });
    }, observerOptions);

    // Observe all animatable elements
    const animatableElements = document.querySelectorAll(`
        .founder-text,
        .founder-visual,
        .mission-card,
        .vision-card,
        .value-item,
        .process-step,
        .impact-stat,
        .story-card,
        .goal,
        .join-option
    `);

    animatableElements.forEach(el => {
        el.classList.add('scroll-reveal');
        observer.observe(el);
    });
}

/**
 * Animate counters when they come into view
 */
function initCounterAnimations() {
    const counters = document.querySelectorAll('.stat-number');
    
    counters.forEach(counter => {
        counter.dataset.animated = 'false';
    });
}

function animateCounter(statElement) {
    const counter = statElement.querySelector('.stat-number');
    if (!counter || counter.dataset.animated === 'true') return;
    
    const target = parseInt(counter.textContent.replace(/\D/g, ''));
    const suffix = counter.textContent.replace(/[\d\s]/g, '');
    const duration = 2000; // 2 seconds
    const step = target / (duration / 16); // 60fps
    
    let current = 0;
    counter.dataset.animated = 'true';
    
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
 * Progressive disclosure for story sections
 */
function initProgressiveDisclosure() {
    const storyHighlight = document.querySelector('.story-highlight');
    
    if (storyHighlight) {
        storyHighlight.addEventListener('click', function() {
            this.classList.toggle('expanded');
            
            // Add a subtle pulse effect
            this.style.transform = 'scale(1.02)';
            setTimeout(() => {
                this.style.transform = '';
            }, 200);
        });
    }
    
    // Add click handlers for value items to show more detail
    const valueItems = document.querySelectorAll('.value-item');
    valueItems.forEach(item => {
        item.addEventListener('click', function() {
            // Remove active class from other items
            valueItems.forEach(other => other.classList.remove('active'));
            
            // Add active class to clicked item
            this.classList.toggle('active');
            
            // Track interaction
            trackInteraction('value_item_click', this.querySelector('h3').textContent);
        });
    });
}

/**
 * Smooth scrolling for internal links
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
                trackInteraction('internal_navigation', href);
            }
        });
    });
}

/**
 * Parallax effects for background elements
 */
function initParallaxEffects() {
    const floatingElements = document.querySelectorAll('.floating-element');
    
    window.addEventListener('scroll', () => {
        const scrolled = window.pageYOffset;
        const rate = scrolled * -0.5;
        
        floatingElements.forEach((element, index) => {
            const speed = 0.5 + (index * 0.2); // Different speeds for each element
            element.style.transform = `translate3d(0, ${rate * speed}px, 0)`;
        });
    });
}

/**
 * Enhanced interactions for story cards
 */
function initStoryCardInteractions() {
    const storyCards = document.querySelectorAll('.story-card');
    
    storyCards.forEach(card => {
        card.addEventListener('mouseenter', function() {
            // Add subtle animation
            this.style.transform = 'translateY(-8px) scale(1.02)';
        });
        
        card.addEventListener('mouseleave', function() {
            this.style.transform = 'translateY(-3px) scale(1)';
        });
        
        card.addEventListener('click', function() {
            // Create a modal or expanded view effect
            showStoryModal(this);
        });
    });
}

/**
 * Show expanded story modal
 */
function showStoryModal(storyCard) {
    const quote = storyCard.querySelector('.story-quote').textContent;
    const author = storyCard.querySelector('.story-author').textContent;
    
    // Create modal overlay
    const modal = document.createElement('div');
    modal.className = 'story-modal';
    modal.innerHTML = `
        <div class="story-modal-content">
            <button class="modal-close">&times;</button>
            <div class="modal-quote">${quote}</div>
            <div class="modal-author">${author}</div>
            <div class="modal-actions">
                <button class="share-story">Share This Story</button>
                <button class="read-more">Read More Stories</button>
            </div>
        </div>
    `;
    
    document.body.appendChild(modal);
    
    // Add styles
    modal.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background: rgba(0, 0, 0, 0.8);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 10000;
        opacity: 0;
        transition: opacity 0.3s ease;
    `;
    
    const modalContent = modal.querySelector('.story-modal-content');
    modalContent.style.cssText = `
        background: white;
        padding: 3rem;
        border-radius: 20px;
        max-width: 500px;
        width: 90%;
        text-align: center;
        transform: scale(0.8);
        transition: transform 0.3s ease;
    `;
    
    // Animate in
    setTimeout(() => {
        modal.style.opacity = '1';
        modalContent.style.transform = 'scale(1)';
    }, 10);
    
    // Close handlers
    modal.querySelector('.modal-close').addEventListener('click', closeModal);
    modal.addEventListener('click', (e) => {
        if (e.target === modal) closeModal();
    });
    
    function closeModal() {
        modal.style.opacity = '0';
        modalContent.style.transform = 'scale(0.8)';
        setTimeout(() => {
            document.body.removeChild(modal);
        }, 300);
    }
    
    // Track modal interaction
    trackInteraction('story_modal_opened', author);
}

/**
 * Initialize timeline scroll effects
 */
function initTimelineEffects() {
    const processSteps = document.querySelectorAll('.process-step');
    
    const timelineObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('timeline-active');
                
                // Animate the step number
                const stepNumber = entry.target.querySelector('.step-number');
                if (stepNumber) {
                    stepNumber.style.transform = 'scale(1.2)';
                    setTimeout(() => {
                        stepNumber.style.transform = 'scale(1)';
                    }, 300);
                }
            }
        });
    }, {
        rootMargin: '-20% 0px -20% 0px',
        threshold: 0.5
    });
    
    processSteps.forEach(step => {
        timelineObserver.observe(step);
    });
}

/**
 * Add hover effects to goal cards
 */
function initGoalCardEffects() {
    const goalCards = document.querySelectorAll('.goal');
    
    goalCards.forEach(card => {
        card.addEventListener('mouseenter', function() {
            // Create ripple effect
            const ripple = document.createElement('div');
            ripple.style.cssText = `
                position: absolute;
                border-radius: 50%;
                background: rgba(255, 255, 255, 0.3);
                pointer-events: none;
                transform: scale(0);
                animation: ripple 0.6s linear;
                top: 50%;
                left: 50%;
                width: 20px;
                height: 20px;
                margin-top: -10px;
                margin-left: -10px;
            `;
            
            this.style.position = 'relative';
            this.appendChild(ripple);
            
            setTimeout(() => {
                if (ripple.parentNode) {
                    ripple.parentNode.removeChild(ripple);
                }
            }, 600);
        });
    });
    
    // Add ripple animation CSS
    const style = document.createElement('style');
    style.textContent = `
        @keyframes ripple {
            to {
                transform: scale(4);
                opacity: 0;
            }
        }
    `;
    document.head.appendChild(style);
}

/**
 * Analytics and tracking
 */
function trackPageViews() {
    // Track page view
    if (typeof gtag !== 'undefined') {
        gtag('event', 'page_view', {
            'page_title': 'About Us',
            'page_location': window.location.href
        });
    }
    
    // Track scroll depth
    let maxScroll = 0;
    window.addEventListener('scroll', () => {
        const scrollPercent = Math.round((window.scrollY / (document.body.scrollHeight - window.innerHeight)) * 100);
        
        if (scrollPercent > maxScroll) {
            maxScroll = scrollPercent;
            
            // Track scroll milestones
            if (maxScroll >= 25 && maxScroll < 50) {
                trackInteraction('scroll_depth', '25_percent');
            } else if (maxScroll >= 50 && maxScroll < 75) {
                trackInteraction('scroll_depth', '50_percent');
            } else if (maxScroll >= 75 && maxScroll < 90) {
                trackInteraction('scroll_depth', '75_percent');
            } else if (maxScroll >= 90) {
                trackInteraction('scroll_depth', '90_percent');
            }
        }
    });
}

function trackInteraction(action, label) {
    // Google Analytics tracking
    if (typeof gtag !== 'undefined') {
        gtag('event', action, {
            'event_category': 'about_page',
            'event_label': label,
            'page_title': 'About Us'
        });
    }
    
    // Custom tracking can be added here
    console.log(`About page interaction: ${action} - ${label}`);
}

/**
 * Keyboard navigation enhancements
 */
function initKeyboardNavigation() {
    document.addEventListener('keydown', function(e) {
        // Press 'j' to scroll to next section
        if (e.key === 'j' || e.key === 'J') {
            if (!e.ctrlKey && !e.altKey && !e.metaKey) {
                scrollToNextSection();
                e.preventDefault();
            }
        }
        
        // Press 'k' to scroll to previous section
        if (e.key === 'k' || e.key === 'K') {
            if (!e.ctrlKey && !e.altKey && !e.metaKey) {
                scrollToPreviousSection();
                e.preventDefault();
            }
        }
    });
}

function scrollToNextSection() {
    const sections = document.querySelectorAll('section');
    const currentScroll = window.pageYOffset;
    
    for (let section of sections) {
        if (section.offsetTop > currentScroll + 100) {
            section.scrollIntoView({ behavior: 'smooth' });
            break;
        }
    }
}

function scrollToPreviousSection() {
    const sections = Array.from(document.querySelectorAll('section')).reverse();
    const currentScroll = window.pageYOffset;
    
    for (let section of sections) {
        if (section.offsetTop < currentScroll - 100) {
            section.scrollIntoView({ behavior: 'smooth' });
            break;
        }
    }
}

/**
 * Initialize all enhanced features
 */
document.addEventListener('DOMContentLoaded', function() {
    initScrollAnimations();
    initCounterAnimations();
    initProgressiveDisclosure();
    initSmoothScrolling();
    initParallaxEffects();
    initStoryCardInteractions();
    initTimelineEffects();
    initGoalCardEffects();
    initKeyboardNavigation();
    trackPageViews();
});

/**
 * Export functions for external use
 */
window.AboutPageUtils = {
    trackInteraction,
    animateCounter,
    showStoryModal
};